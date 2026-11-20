#!/usr/bin/env python3
"""Rebuildable inventory of Clang toolchain display strings.

Three inventories share one LLVM source pin:

* ``clang``: every TableGen diagnostic a compiler invocation can emit
  (Sema/Parse/Lex/Driver/AST/Frontend/Common/Serialization/Comment).
* ``clangd``: the subset reachable through the language server (kept in
  manifests/clangd-coverage.json).
* ``clang-tidy``: every registered check and the diagnostic messages it
  reports, scanned from clang-tools-extra/clang-tidy sources.

Usage:
    python3 tools/toolchain_inventory.py coverage --source-root <llvm checkout>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import diagnostic_inventory as diag  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
TOOLCHAIN = ROOT / "manifests/toolchain.json"
COMPILER_OUT = ROOT / "manifests/clang-coverage.json"
TIDY_OUT = ROOT / "manifests/clang-tidy-coverage.json"
ANALYZER_CHECKERS = Path("clang/include/clang/StaticAnalyzer/Checkers/Checkers.td")

COMPILER_COMPONENTS = ("Sema", "Parse", "Lex", "Driver", "AST", "Frontend",
                       "Common", "Serialization", "Comment")
COMPILER_EXCLUDED = ("InstallAPI", "CrossTU", "Refactoring", "Trap")
COMPILER_EXCLUDED_REASON = (
    "those components only report through non-compiler entry points "
    "(install-API scan, cross-TU analysis, refactoring tools, or pragma trap) "
    "and are not part of a clang/clang++ compilation display surface"
)

CHECK_RE_MULTILINE = re.compile(
    r"registerCheck<([A-Za-z0-9_:]+)>\s*\(\s*\n?\s*\"([^\"]+)\"", re.M)
DIAG_RE = re.compile(r"(?:\.|(?<![A-Za-z0-9_]))diag\s*\(")
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')
CONST_RE = re.compile(r'\b([A-Za-z_]\w*)(?:\[\])?\s*=\s*((?:"(?:\\.|[^"\\])*"\s*)+);')
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*")
NOTE_FLAG = re.compile(r"DiagnosticIDs::Note")
FIX_FLAG = re.compile(r"FixItHint")
def load_toolchain() -> dict:
    return json.loads(TOOLCHAIN.read_text(encoding="utf-8"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def compiler_records(defs: dict) -> list[dict]:
    groups = diag.collect_group_options(defs)
    records = []
    for name, record in defs.items():
        if record.get("!anonymous"):
            continue
        component = record.get("Component")
        if not isinstance(component, str) or component not in COMPILER_COMPONENTS:
            continue
        if "Diagnostic" not in record.get("!superclasses", []):
            continue
        summary = record.get("Summary")
        if not isinstance(summary, str) or not summary:
            continue
        class_name = diag._def_name(record.get("Class"))
        group_defs = record.get("Group")
        options = groups.get(group_defs.get("def", ""), []) if isinstance(group_defs, dict) else []
        locs = record.get("!locs") or []
        source_file = f"clang/include/clang/Basic/{Path(locs[0].rsplit(':', 1)[0]).name}" if locs else diag.TBLGEN_TARGET
        records.append({
            "id": name,
            "source": source_file,
            "line": int(locs[0].rsplit(":", 1)[1]) if locs else 0,
            "component": component,
            "class": class_name,
            "severity": diag.SEVERITY.get(class_name, "error"),
            "default_ignore": "DefaultIgnore" in record.get("!superclasses", []),
            "groups": options,
            "summary": summary,
            "variants": [],
            "variants_capped": False,
            "free_text": name in FREE_TEXT,
            "untranslated_multi_digit": False,
        })
    records.sort(key=lambda item: item["id"])
    return records


# TableGen records whose rendered message is entirely user-provided text.
FREE_TEXT = {
    "err_apinotes_message", "note_apinotes_message", "warn_apinotes_message",
    "err_diagnose_if_succeeded", "warn_diagnose_if_succeeded", "err_inline_ms_asm_parsing",
    "err_pp_hash_error", "pp_hash_warning", "err_pragma_message", "warn_pragma_message",
    "warn_unsupported_operation", "ext_vector_subscript_requires_const",
}


def fill_variants(record: dict, substitutions: dict) -> None:
    canonical: list[str] = []
    seen: set[str] = set()
    for raw in diag.normalize_template(record["summary"], substitutions):
        for template in diag.expand_plural_suffixes(diag.strip_simple_modifiers(raw)):
            if template not in seen:
                seen.add(template)
                canonical.append(template)
    record["untranslated_multi_digit"] = any(
        re.search(r"%(\d{2,})(?!\d)", template.replace("%%", "")) or diag.STRUCTURAL_RE.search(template)
        for template in canonical
    )
    if len(canonical) > diag.VARIANT_CAP:
        record["variants_capped"] = True
        canonical = canonical[: diag.VARIANT_CAP]
    record["variants"] = canonical


def codes(record: dict) -> list[str]:
    return [f"-W{group}" for group in record["groups"]] or [record["id"].removeprefix("err_").removeprefix("warn_")]


# ---------------------------------------------------------------------------
# clang-tidy
# ---------------------------------------------------------------------------

def literal_value(token: str) -> str:
    body = token[1:-1]
    return (body.replace('\\"', '"').replace('\\n', '\n')
            .replace('\\t', '\t').replace('\\\\', '\\'))


def literal_expression(text: str) -> str | None:
    """Return the joined value when the expression is only string literals."""
    stripped = re.sub(r"//[^\n]*|/\\*.*?\\*/", " ", text, flags=re.S).strip()
    literals = STRING_RE.findall(stripped)
    if not literals:
        return None
    remainder = STRING_RE.sub("", stripped).strip()
    if remainder:
        return None
    return "".join(literal_value(token) for token in literals)


def collect_constants(text: str) -> dict[str, list[str]]:
    constants: dict[str, list[str]] = {}
    for match in CONST_RE.finditer(text):
        value = literal_expression(match.group(2))
        if value is not None:
            values = constants.setdefault(match.group(1), [])
            if value not in values:
                values.append(value)
    return constants


def matching_close(text: str, open_index: int) -> int | None:
    depth = 0
    quote = None
    index = open_index
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def split_arguments(text: str) -> list[str]:
    parts, depth, current, quote = [], 0, [], None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == "\\":
                current.append(text[index + 1: index + 2])
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            current.append(char)
        elif char in "([{":
            depth += 1
            current.append(char)
        elif char in ")]}":
            depth -= 1
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    parts.append("".join(current))
    return [part.strip() for part in parts]


def message_candidates(argument: str, constants: dict[str, list[str]]) -> list[str]:
    results: list[str] = []
    direct = literal_expression(argument)
    if direct is not None:
        results.append(direct)
    for identifier in IDENT_RE.findall(argument):
        for value in constants.get(identifier.split("::")[-1], []):
            if value not in results:
                results.append(value)
    return results


def check_messages(text: str, constants: dict[str, list[str]]) -> tuple[list[dict], list[dict]]:
    messages: list[dict] = []
    unresolved = []
    for match in DIAG_RE.finditer(text):
        open_index = text.index("(", match.start())
        close_index = matching_close(text, open_index)
        if close_index is None:
            continue
        arguments = split_arguments(text[open_index + 1: close_index])
        if not arguments:
            continue
        message_index = 1 if len(arguments) > 1 else 0
        first = arguments[0]
        if first.startswith('"') or (len(arguments) == 1 and first in constants):
            message_index = 0
        argument = arguments[message_index]
        candidates = message_candidates(argument, constants)
        note = bool(len(arguments) > message_index + 1 and NOTE_FLAG.search(arguments[message_index + 1]))
        fix = bool(FIX_FLAG.search(text[close_index + 1:].split(';', 1)[0]))
        line = text.count("\n", 0, match.start()) + 1
        if not candidates:
            unresolved.append({"line": line, "reason": "non-literal diagnostic argument"})
        for message in candidates:
            messages.append({
                "message": message,
                "note": note,
                "fix": fix,
                "line": line,
                "placeholders": sorted({int(value) for value in re.findall(r"%(\d+)(?!\d)", message)}),
            })
    # The same literal can appear in several branches; keep one record per
    # (message, note) pair with the first source line.
    unique: dict[tuple[str, bool], dict] = {}
    for message in messages:
        key = (message["message"], message["note"])
        unique.setdefault(key, message)
    return list(unique.values()), unresolved


def check_sources(tree: Path) -> tuple[list[dict], list[str]]:
    checks, errors = [], []
    registered: list[tuple[str, str]] = []
    for module in sorted(tree.glob("*/*TidyModule.cpp")):
        text = module.read_text(encoding="utf-8", errors="replace")
        for match in CHECK_RE_MULTILINE.finditer(text):
            registered.append((match.group(1), match.group(2)))
    registered.sort(key=lambda item: (item[1], item[0]))
    for class_name, check_name in registered:
        module_dir = tree / check_name.split("-")[0]
        short = class_name.split("::")[-1]
        candidates = [module_dir / f"{short}.cpp", module_dir / f"{short}.h"]
        source = next((path for path in candidates if path.is_file()), None)
        if source is None:
            found = sorted(tree.rglob(f"{short}.cpp")) + sorted(tree.rglob(f"{short}.h"))
            source = found[0] if found else None
        if source is None:
            errors.append(f"{check_name}: source for {class_name} not found")
            checks.append({"name": check_name, "class": class_name, "source": None, "messages": [],
                           "unresolved": [{"reason": "implementation not located"}]})
            continue
        text = source.read_text(encoding="utf-8", errors="replace")
        constants = collect_constants(text)
        messages, unresolved = check_messages(text, constants)
        if not messages:
            errors.append(f"{check_name}: no diagnostic message found in {source.name}")
        checks.append({
            "name": check_name,
            "class": class_name,
            "source": source.relative_to(tree.parent.parent).as_posix(),
            "messages": messages,
            "unresolved": unresolved,
        })
    return checks, errors


def analyzer_checks(source_root: Path) -> list[dict]:
    path = source_root / ANALYZER_CHECKERS
    result = diag.run([diag._find_tblgen(), str(path), "-I", str(path.parent), "--dump-json"])
    if result.returncode:
        raise diag.InventoryError(result.stderr.strip())
    definitions = json.loads(result.stdout)
    checks = []
    for row in definitions.values():
        if not isinstance(row, dict) or "Checker" not in row.get("!superclasses", []):
            continue
        names = [row["CheckerName"]]
        parent = row["ParentPackage"]
        while parent:
            package = definitions[parent["def"]]
            names.insert(0, package["PackageName"])
            parent = package["ParentPackage"]
        checks.append({"name": "clang-analyzer-" + ".".join(names), "id": row["!name"],
                       "source": ANALYZER_CHECKERS.as_posix(), "line": int(row["!locs"][0].split(":")[-1]),
                       "hidden": bool(row["Hidden"]), "messages": [],
                       "reason": "analyzer report and path-note strings require a separate source audit"})
    return sorted(checks, key=lambda row: row["name"])


def build(toolchain: dict, source_root: Path) -> tuple[dict, dict]:
    defs = diag.tblgen_records(source_root)
    substitutions = diag.collect_substitutions(defs)
    records = compiler_records(defs)
    for record in records:
        fill_variants(record, substitutions)
    compiler = {
        "schema": 1,
        "upstream": toolchain["llvm"],
        "generator": "tools/toolchain_inventory.py",
        "tool": "clang",
        "reachable_components": list(COMPILER_COMPONENTS),
        "excluded_components": list(COMPILER_EXCLUDED),
        "excluded_reason": COMPILER_EXCLUDED_REASON,
        "variant_cap": diag.VARIANT_CAP,
        "counts": {
            "diagnostics": len(records),
            "variants": sum(len(row["variants"]) for row in records),
            "diagnostics_with_capped_variants": sum(row["variants_capped"] for row in records),
            "free_text": sum(row["free_text"] for row in records),
            "by_component": dict(Counter(row["component"] for row in records)),
            "by_severity": dict(Counter(row["severity"] for row in records)),
        },
        "diagnostics": records,
    }
    tidy_tree = source_root / "clang-tools-extra/clang-tidy"
    checks, errors = check_sources(tidy_tree)
    analyzer = analyzer_checks(source_root)
    for check in checks:
        for message in check["messages"]:
            message["codes"] = [check["name"]]
    tidy = {
        "schema": 1,
        "upstream": toolchain["llvm"],
        "generator": "tools/toolchain_inventory.py",
        "tool": "clang-tidy",
        "counts": {
            "checks": len(checks),
            "analyzer_checkers": len(analyzer),
            "messages": sum(len(check["messages"]) for check in checks),
            "checks_with_fixes": sum(any(message["fix"] for message in check["messages"]) for check in checks),
            "notes": sum(message["note"] for check in checks for message in check["messages"]),
            "scan_errors": len(errors),
            "unresolved_calls": sum(len(check["unresolved"]) for check in checks),
        },
        "scan_errors": errors,
        "checks": checks,
        "analyzer_checkers": analyzer,
    }
    return compiler, tidy


def write_json(path: Path, value: dict) -> None:
    import os
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("coverage",))
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args(argv)
    toolchain = load_toolchain()
    commit = toolchain["llvm"]["commit"]
    try:
        diag.verify_checkout(args.source_root, commit)
    except diag.InventoryError as exc:
        print(f"INVENTORY_ERROR={exc}", file=sys.stderr)
        return 1
    try:
        compiler, tidy = build(toolchain, args.source_root)
    except diag.InventoryError as exc:
        print(f"INVENTORY_ERROR={exc}", file=sys.stderr)
        return 1
    write_json(COMPILER_OUT, compiler)
    write_json(TIDY_OUT, tidy)
    print(
        "TOOLCHAIN_INVENTORY=PASS "
        f"compiler={compiler['counts']['diagnostics']} compiler_variants={compiler['counts']['variants']} "
        f"tidy_checks={tidy['counts']['checks']} tidy_messages={tidy['counts']['messages']} "
        f"tidy_fix_checks={tidy['counts']['checks_with_fixes']} scan_errors={tidy['counts']['scan_errors']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
