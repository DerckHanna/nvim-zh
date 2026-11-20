#!/usr/bin/env python3
"""Record stdout, stderr, exits, parsed diagnostic fields and fix files outside the checkout."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEVEL = r"(?P<level>fatal error|error|warning|note|remark): (?P<message>.+)"
LOCATED = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<column>\d+): " + LEVEL)
DRIVER = re.compile(r"^(?:(?P<driver>clang(?:\+\+)?): )?" + LEVEL)
LINKER = re.compile(r"^(?P<driver>(?:[^: ]*/)?(?:ld(?:[.-][^: ]+)?|lld|as)): (?P<message>.*)")
CODE = re.compile(r"^(?P<body>.+) \[(?P<code>-W[^\]]+|[\w.]+-[\w.%-]+)\]$")
CASES = {
    "preprocessor.c": [],
    "syntax.c": [],
    "types.c": [],
    "includes.c": [],
    "templates.cpp": [],
    "constraints.cpp": [],
    "abi.cpp": ["-mno-avx", "-c", "-o", "abi.o"],
    "lsp.cpp": [],
    "collision.c": [],
}
CHECKS = ("modernize-use-nullptr", "readability-redundant-control-flow",
          "bugprone-easily-swappable-parameters", "misc-unused-parameters",
          "readability-else-after-return", "modernize-use-auto")


def run(argv: list[str], cwd: Path) -> dict:
    result = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=45,
                            env=dict(os.environ, LC_ALL="C.UTF-8"))
    return {"argv": argv, "exit": result.returncode,
            "stdout": result.stdout.decode(), "stderr": result.stderr.decode()}


def parse(text: str, driver: str) -> list[dict]:
    records = []
    previous_check = None
    for raw in text.splitlines():
        if raw.startswith("fix-it:"):
            records.append({"kind": "fix_edit", "raw": raw, "origin": driver})
            continue
        if raw.startswith(("In file included from ", "                 from ")):
            records.append({"kind": "include_stack", "raw": raw, "origin": driver})
            continue
        match = LOCATED.match(raw) or DRIVER.match(raw) or LINKER.match(raw)
        if not match:
            continue
        entry = {k: v for k, v in match.groupdict().items() if v is not None}
        for field in ("line", "column"):
            if field in entry:
                entry[field] = int(entry[field])
        entry["kind"] = "diagnostic"
        entry["origin"] = entry.pop("driver", driver)
        entry["raw"] = raw
        code = CODE.fullmatch(entry["message"])
        if code:
            entry["message"], entry["code"] = code.group("body", "code")
        if driver == "clang-tidy" and entry.get("level") == "note" and not code:
            entry["associated_check"] = previous_check
        elif driver == "clang-tidy":
            previous_check = entry.get("code")
        records.append(entry)
    return records


def checked(result: dict, driver: str, interface: str, case: str, expected: int) -> dict:
    if result["exit"] != expected:
        raise RuntimeError(f"{case} returned {result['exit']}, expected {expected}: {result}")
    result.update(tool=driver, interface=interface, case=case,
                  diagnostics=parse(result["stdout"] + result["stderr"], driver))
    return result


def observe(project: Path, clang: str, clangxx: str, tidy: str) -> dict:
    compiler, tidy_runs = [], []
    for program, driver in ((clang, "clang"), (clangxx, "clang++")):
        for name, flags in CASES.items():
            language = "c" if name.endswith(".c") else "c++"
            standard = "-std=c11" if language == "c" else "-std=c++20"
            invocation = [program, "-x", language, standard, "-Wall", "-Wextra",
                          "-fdiagnostics-parseable-fixits", *(flags or ["-fsyntax-only"]), name]
            compiler.append(checked(run(invocation, project), driver, "quickfix", name, int(name != "abi.cpp")))
        for case, flags in {"no-input": [], "unknown-option": ["--nvim-zh-unknown-option"],
                            "missing-file": ["-fsyntax-only", "不存在.c"],
                            "link": ["link.c", "-o", "应用"]}.items():
            compiler.append(checked(run([program, *flags], project), driver, "driver", case, 1))
        compiler.append(checked(run([program, "-x", "c", "success.c", "-o", "应用"], project),
                                driver, "quickfix", "success.c", 0))
    for check in CHECKS:
        args = [tidy, "tidy.cpp", "--checks=-*," + check]
        tidy_runs.append(checked(run([*args, "--", "-std=c++20"], project), "clang-tidy", "quickfix", check, 0))
    fix_args = [tidy, "tidy.cpp", "--checks=-*,modernize-use-nullptr"]
    old = (project / "tidy.cpp").read_text()
    export = checked(run([*fix_args, "--export-fixes=修复.yaml", "--", "-std=c++20"], project),
                     "clang-tidy", "quickfix", "export-fixes", 0)
    apply = checked(run([*fix_args, "--fix", "--", "-std=c++20"], project),
                    "clang-tidy", "quickfix", "apply", 0)
    recheck = checked(run([*fix_args, "--", "-std=c++20"], project), "clang-tidy", "quickfix", "recheck", 0)
    new = (project / "tidy.cpp").read_text()
    if "nullptr" not in new or new == old or recheck["diagnostics"]:
        raise RuntimeError("clang-tidy fix and recheck did not produce the expected change")
    listed = run([tidy, "--list-checks", "--checks=*"], project)
    if listed["exit"] != 0 or not listed["stdout"].startswith("Enabled checks:"):
        raise RuntimeError(f"could not list checks: {listed}")
    return {"schema": 1, "compiler": compiler, "clang_tidy": tidy_runs,
            "fix": {"export": export, "yaml": (project / "修复.yaml").read_text(),
                    "apply": apply, "recheck": recheck, "before": old, "after": new},
            "enabled_checks": sorted(x.strip() for x in listed["stdout"].splitlines()[1:] if x.strip()),
            "binaries": {tool: {"version": run([tool, "--version"], project),
                                "sha256": hashlib.file_digest(Path(tool).open("rb"), "sha256").hexdigest()}
                         for tool in (clang, clangxx, tidy)}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=ROOT / "tests/fixtures/clang-toolchain/corpus")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--clangxx", default="clang++")
    parser.add_argument("--clang-tidy", default="clang-tidy")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.is_relative_to(ROOT):
        parser.error("--output must be outside the checkout")
    output.parent.mkdir(parents=True, exist_ok=True)
    executables = [shutil.which(tool) for tool in (args.clang, args.clangxx, args.clang_tidy)]
    if not all(executables):
        parser.error("clang, clang++ and clang-tidy must all be installed")
    with tempfile.TemporaryDirectory(prefix="nvim-zh-clang-", dir=output.parent) as temporary:
        project = Path(temporary) / "编译练习"
        shutil.copytree(args.corpus, project)
        value = observe(project, *executables)
    output.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"OBSERVE=PASS compiler_runs={len(value['compiler'])} tidy_checks={len(value['enabled_checks'])} file={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
