#!/usr/bin/env python3
"""Inventory clangd-reachable Clang diagnostics from the pinned llvm-project.

Reads manifests/upstreams.json for the pinned llvm-project revision, verifies
the pinned sparse checkout read-only, extracts every Clang TableGen diagnostic
record reachable through clangd via llvm-tblgen, and emits
manifests/clangd-coverage.json.

For every reachable diagnostic the manifest records: upstream version/commit,
source location, diagnostic ID, component, severity class, raw TableGen format
string, canonical engine templates (%select/%diff/%plural/%sub expanded), the
-W warning group option names, and translation status fields the catalog
pipeline fills in.

Usage:
    python3 tools/diagnostic_inventory.py coverage  # build manifests/clangd-coverage.json
    python3 tools/diagnostic_inventory.py stats     # compare coverage with the PO catalog
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "manifests/upstreams.json"
COVERAGE = ROOT / "manifests/clangd-coverage.json"

# Components whose diagnostics clangd can emit. clangd parses, lexes, and
# sema-checks in-process and never writes PCH files; Driver/Frontend/InstallAPI
# diagnostics belong to compiler-driver processes, CrossTU/Refactoring/Trap to
# paths the language server does not take.
REACHABLE_COMPONENTS = ("Sema", "Parse", "Lex", "Common", "AST", "Comment")
EXCLUDED_COMPONENTS = ("Driver", "Frontend", "InstallAPI", "CrossTU", "Refactoring", "Trap")
EXCLUDED_REASON = ("component diagnostics belong to compiler-driver processes or "
                   "non-language-server paths; clangd parses, lexes, and sema-checks "
                   "in-process and never writes PCH files")

TBLGEN_TARGET = "clang/include/clang/Basic/Diagnostic.td"
TBLGEN_INCLUDE = "clang/include/clang/Basic"

SCHEMA = 1
# Canonical templates per diagnostic are capped so a pathological modifier
# product cannot explode the manifest; capped records keep their first variants
# and are reported so maintainers see the limitation.
VARIANT_CAP = 64
SEVERITY = {
    "CLASS_ERROR": "error",
    "CLASS_WARNING": "warning",
    "CLASS_EXTENSION": "extension",
    "CLASS_REMARK": "remark",
    "CLASS_NOTE": "note",
    "CLASS_TRAP": "trap",
}


class InventoryError(Exception):
    pass


def run(argv: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, check=False, timeout=timeout)


def load_upstream() -> dict:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    upstream = data["upstreams"]["clangd"]
    return {
        "repository": upstream["repository"],
        "version": upstream["version"],
        "commit": upstream["commit"],
        "cache": ROOT / ".llvm-upstream/llvm-project",
    }


def verify_checkout(cache: Path, commit: str) -> None:
    if not cache.is_dir():
        raise InventoryError(f"{cache}: llvm-project checkout missing")
    probe = run(["git", "-C", str(cache), "cat-file", "-t", commit])
    if probe.returncode != 0 or probe.stdout.strip() != "commit":
        raise InventoryError(f"{cache}: pinned commit {commit} not present")
    head = run(["git", "-C", str(cache), "rev-parse", "HEAD"])
    if head.returncode == 0 and head.stdout.strip() != commit:
        raise InventoryError(f"{cache}: HEAD {head.stdout.strip()} is not pinned {commit}")


def _find_tblgen() -> str:
    from shutil import which
    found = which("llvm-tblgen") or which("llvm-tblgen-23") or which("llvm-tblgen-18")
    if not found:
        raise InventoryError("llvm-tblgen not found; install llvm (Arch: pacman -S llvm)")
    return found


def tblgen_records(cache: Path) -> dict:
    result = run([_find_tblgen(), str(cache / TBLGEN_TARGET), "-I", str(cache / TBLGEN_INCLUDE),
                  "--dump-json"], timeout=600)
    if result.returncode != 0:
        raise InventoryError(f"llvm-tblgen failed: {result.stderr.strip()[:400]}")
    data = json.loads(result.stdout)
    return {name: record for name, record in data.items()
            if not name.startswith("!") and isinstance(record, dict)}


# ---------------------------------------------------------------------------
# TableGen format-string helpers
# ---------------------------------------------------------------------------

def split_top_level(text: str, separator: str) -> list[str]:
    """Split on separator at brace depth zero (quotes are literal content)."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if depth == 0 and text.startswith(separator, i):
            parts.append("".join(current))
            current = []
            i += len(separator)
            continue
        current.append(ch)
        i += 1
    parts.append("".join(current))
    return parts


def find_matching_brace(text: str, open_index: int) -> int:
    depth = 0
    for i in range(open_index, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    raise InventoryError(f"unbalanced braces in format string: {text!r}")


STRUCTURAL_RE = re.compile(r"%(select|plural|diff|sub)\{")
# %enum_select<Name>{%Tag{text}|...}N — tagged select; the rendered text is the
# brace body of the selected tag (ScanFormat skips %X sequences, so a literal
# backslash before | or } never escapes the split).
ENUM_SELECT_RE = re.compile(r"%enum_select<([A-Za-z_][A-Za-z0-9_]*)>\{")
# Modifiers that only change how one argument renders; the engine captures the
# rendered span, so normalization keeps a bare %N placeholder.
SIMPLE_MODIFIER_RE = re.compile(r"%(ordinal|human|quoted|objcclass|objcinstance|q|s)(\d+)")


def _take_arg_index(tail: str) -> tuple[int, int]:
    """Parse the argument index that follows a structural modifier."""
    match = re.match(r"(\d+)", tail)
    if not match:
        raise InventoryError(f"missing argument index after modifier: {tail[:40]!r}")
    return int(match.group(1)), match.end()


def _substitute_diff_dollars(text: str, first: int, second: int) -> str:
    """Replace the two $ markers of a %diff paired shape with placeholders."""
    if text.count("$") == 2:
        return text.replace("$", f"%{first}", 1).replace("$", f"%{second}", 1)
    return text


def normalize_template(template: str, substitutions: dict[str, str],
                       mapping: list[int] | None = None) -> list[str]:
    """Return canonical templates for one raw TableGen format string.

    Implements the runtime semantics of clang/lib/Basic/Diagnostic.cpp
    (FormatDiagnostic) and the -w documentation renumbering of
    clang/utils/TableGen/ClangDiagnosticsEmitter.cpp (getSubstitutionMappings:
    a substitution body indexes the %sub argument list, mapped through the
    enclosing substitution context).
    """
    if mapping is None:
        mapping = list(range(16))

    def map_index(index: int) -> int:
        return mapping[index] if index < len(mapping) else index

    def renumber(placeholder: re.Match) -> str:
        return f"%{map_index(int(placeholder.group(1)))}"

    match = STRUCTURAL_RE.search(template)
    enum_match = ENUM_SELECT_RE.search(template)
    if enum_match and (not match or enum_match.start() < match.start()):
        open_brace = enum_match.end() - 1
        close_brace = find_matching_brace(template, open_brace)
        inner = template[open_brace + 1 : close_brace]
        after = template[close_brace + 1 :]
        index, consumed = _take_arg_index(after)
        tail = after[consumed:]
        head = template[: enum_match.start()]
        results = []
        for tag in split_top_level(inner, "|"):
            open_tag = tag.find("{")
            body = tag[open_tag + 1 : -1] if open_tag >= 0 and tag.endswith("}") else (tag[open_tag + 1 :] if open_tag >= 0 else "")
            results.extend(normalize_template(head + body + tail, substitutions, mapping))
        return results
    if not match:
        return [re.sub(r"%(\d+)(?!\d)", renumber, template)]

    kind = match.group(1)
    open_brace = match.end() - 1
    close_brace = find_matching_brace(template, open_brace)
    inner = template[open_brace + 1 : close_brace]
    after = template[close_brace + 1 :]
    head = template[: match.start()]
    if kind == "sub":
        index, consumed = _take_arg_index(after)
        indexes = [index]
        while after[consumed : consumed + 1] == ",":
            index, width = _take_arg_index(after[consumed + 1 :])
            indexes.append(index)
            consumed += 1 + width
        name_match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", inner)
        body = substitutions.get(name_match.group(1)) if name_match else None
        if body is None:
            return [template]
        inner_mapping = [map_index(i) for i in indexes]
        tail = after[consumed:]
        results = []
        for body_variant in normalize_template(body, substitutions, inner_mapping):
            results.extend(normalize_template(head + body_variant + tail, substitutions, mapping))
        return results
    if kind == "select":
        index, consumed = _take_arg_index(after)
        tail = after[consumed:]
        results = []
        for alternative in split_top_level(inner, "|"):
            results.extend(normalize_template(head + alternative + tail, substitutions, mapping))
        return results
    if kind == "plural":
        index, consumed = _take_arg_index(after)
        tail = after[consumed:]
        results = []
        for clause in split_top_level(inner, "|"):
            results.extend(normalize_template(head + clause.partition(":")[2] + tail, substitutions, mapping))
        return results
    # diff: %diff{paired|fallback}N,M — the paired shape renders the first
    # argument at the first $ and the second at the second $; the fallback
    # shape omits both arguments.
    first, consumed = _take_arg_index(after)
    if after[consumed : consumed + 1] != ",":
        raise InventoryError(f"%diff without second index: {template[:60]!r}")
    second, width = _take_arg_index(after[consumed + 1 :])
    tail = after[consumed + 1 + width :]
    paired, fallback = split_top_level(inner, "|")
    results = []
    for shape, prepared in ((paired, _substitute_diff_dollars(paired, map_index(first), map_index(second))),
                            (fallback, fallback)):
        results.extend(normalize_template(head + prepared + tail, substitutions, mapping))
    return results


def strip_simple_modifiers(text: str) -> str:
    """Rewrite rendering-only modifiers to bare placeholders (%ordinal0 -> %0)."""
    return SIMPLE_MODIFIER_RE.sub(r"%\2", text)


def expand_plural_suffixes(text: str) -> list[str]:
    """Expand %sN (integer + optional plural s) into both rendered shapes."""
    match = re.search(r"%s(\d)(?!\d)", text)
    if not match:
        return [text]
    # The suffix attaches to the preceding word; emit both spellings.
    without = text[: match.start()] + text[match.end() :]
    with_s = text[: match.start()] + "s" + text[match.end() :]
    return expand_plural_suffixes(without) + expand_plural_suffixes(with_s)


def collect_substitutions(defs: dict) -> dict[str, str]:
    result = {}
    for name, record in defs.items():
        if "TextSubstitution" not in record.get("!superclasses", []):
            continue
        body = record.get("Substitution")
        if isinstance(body, str):
            result[name] = body
    return result


# ---------------------------------------------------------------------------
# Record extraction
# ---------------------------------------------------------------------------

def _def_name(value) -> str:
    if isinstance(value, dict):
        return str(value.get("def", ""))
    return str(value or "")


def collect_group_options(defs: dict) -> dict[str, list[str]]:
    """Map DiagGroup def name -> -W option strings (own name first, then subgroups)."""
    own: dict[str, str] = {}
    children: dict[str, list[str]] = {}
    for name, record in defs.items():
        if "DiagGroup" not in record.get("!superclasses", []):
            continue
        group_name = record.get("GroupName")
        if isinstance(group_name, str) and group_name:
            own[name] = group_name
        children[name] = [_def_name(sub) for sub in record.get("SubGroups") or []]
    expanded: dict[str, list[str]] = {}

    def walk(name: str, seen: frozenset[str]) -> list[str]:
        if name in expanded:
            return expanded[name]
        result = []
        if name in own:
            result.append(own[name])
        for child in children.get(name, []):
            if child in seen:
                continue
            result.append(child)
            result.extend(walk(child, seen | {child}))
        expanded[name] = result
        return result

    for name in list(own):
        walk(name, frozenset((name,)))
    return {name: sorted(set(options)) for name, options in expanded.items()}


def diagnostic_records(defs: dict) -> list[dict]:
    """Filter tblgen defs to diagnostics in clangd-reachable components."""
    groups = collect_group_options(defs)
    records = []
    for name, record in defs.items():
        if record.get("!anonymous"):
            continue
        component = record.get("Component")
        if not isinstance(component, str) or component not in REACHABLE_COMPONENTS:
            continue
        if "Diagnostic" not in record.get("!superclasses", []):
            continue
        summary = record.get("Summary")
        if not isinstance(summary, str) or not summary:
            continue
        class_name = _def_name(record.get("Class"))
        group_defs = record.get("Group")
        options = groups.get(group_defs.get("def", ""), []) if isinstance(group_defs, dict) else []
        locs = record.get("!locs") or []
        source_file = f"clang/include/clang/Basic/{locs[0].split('/')[-1]}" if locs else TBLGEN_TARGET
        records.append({
            "id": name,
            "source": source_file,
            "line": int(locs[0].rsplit(":", 1)[1]) if locs else 0,
            "component": component,
            "class": class_name,
            "severity": SEVERITY.get(class_name, "error"),
            "default_ignore": "DefaultIgnore" in record.get("!superclasses", []),
            "groups": options,
            "summary": summary,
            "variants": [],
            "variants_capped": False,
            "untranslated_multi_digit": False,
        })
    records.sort(key=lambda item: item["id"])
    return records


# ---------------------------------------------------------------------------
# Coverage assembly and commands
# ---------------------------------------------------------------------------

def parse_po_entries(po_path: Path) -> dict[tuple[str, str], str]:
    """Minimal PO reader: (context, msgid) -> msgstr for coverage accounting."""
    entries: dict[tuple[str, str], str] = {}
    context = msgid = msgstr = None
    active = None

    def finish():
        nonlocal context, msgid, msgstr
        if msgid is not None and msgstr is not None:
            entries[(context or "", msgid)] = msgstr
        context = msgid = msgstr = None

    for raw in po_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^(msgctxt|msgid|msgstr)\s+\"(.*)\"$", line)
        if match:
            keyword, value = match.group(1), match.group(2)
            if keyword in ("msgctxt", "msgid") and msgid is not None:
                finish()
            if keyword == "msgctxt":
                context = value
            elif keyword == "msgid":
                msgid = value
            else:
                msgstr = value
            active = keyword
            continue
        if line.startswith('"') and active:
            extra = line[1:-1]
            if active == "msgctxt":
                context += extra
            elif active == "msgid":
                msgid += extra
            else:
                msgstr += extra
    finish()
    return entries


def build_coverage(upstream: dict, defs: dict) -> dict:
    records = diagnostic_records(defs)
    substitutions = collect_substitutions(defs)
    capped_count = 0
    unsupported_count = 0
    variant_total = 0
    for record in records:
        canonical: list[str] = []
        seen: set[str] = set()
        for raw in normalize_template(record["summary"], substitutions):
            for template in expand_plural_suffixes(strip_simple_modifiers(raw)):
                if template not in seen:
                    seen.add(template)
                    canonical.append(template)
        unsupported = any(
            re.search(r"%(\d{2,})(?!\d)", template.replace("%%", "")) or STRUCTURAL_RE.search(template)
            for template in canonical
        )
        record["untranslated_multi_digit"] = unsupported
        unsupported_count += unsupported
        if len(canonical) > VARIANT_CAP:
            record["variants_capped"] = True
            canonical = canonical[:VARIANT_CAP]
        record["variants"] = canonical
        capped_count += bool(record.get("variants_capped"))
        variant_total += len(canonical)
    return {
        "schema": SCHEMA,
        "upstream": {
            "repository": upstream["repository"],
            "version": upstream["version"],
            "commit": upstream["commit"],
        },
        "generator": "tools/diagnostic_inventory.py",
        "reachable_components": list(REACHABLE_COMPONENTS),
        "excluded_components": list(EXCLUDED_COMPONENTS),
        "excluded_reason": EXCLUDED_REASON,
        "variant_cap": VARIANT_CAP,
        "counts": {
            "diagnostics": len(records),
            "variants": variant_total,
            "diagnostics_with_capped_variants": capped_count,
            "diagnostics_outside_digit_arguments": unsupported_count,
            "by_severity": dict(Counter(record["severity"] for record in records)),
            "by_component": dict(Counter(record["component"] for record in records)),
        },
        "diagnostics": records,
    }


def write_coverage(coverage: dict) -> None:
    import os
    temporary = COVERAGE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(coverage, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    os.replace(temporary, COVERAGE)


def cmd_coverage(upstream: dict, defs: dict) -> int:
    coverage = build_coverage(upstream, defs)
    write_coverage(coverage)
    counts = coverage["counts"]
    print(f"COVERAGE_WRITE=PASS diagnostics={counts['diagnostics']} variants={counts['variants']} "
          f"capped={counts['diagnostics_with_capped_variants']} "
          f"multi_digit={counts['diagnostics_outside_digit_arguments']} file={COVERAGE}")
    return 0


def cmd_stats(upstream: dict, defs: dict) -> int:
    coverage = build_coverage(upstream, defs)
    counts = coverage["counts"]
    po = parse_po_entries(ROOT / "translations/po/zh_CN/clangd.po")
    supportable = [record for record in coverage["diagnostics"] if not record["untranslated_multi_digit"]]
    covered = sum(1 for record in supportable if any(("diagnostic", v) in po for v in record["variants"]))
    total = len(supportable)
    print(f"UPSTREAM_VERSION={upstream['version']} commit={upstream['commit']}")
    print(f"DIAGNOSTICS={counts['diagnostics']} variants={counts['variants']} "
          f"multi_digit={counts['diagnostics_outside_digit_arguments']} capped={counts['diagnostics_with_capped_variants']}")
    print(f"TRANSLATABLE={total} covered={covered} percent={100.0 * covered / max(total, 1):.1f}%")
    print(f"PO_ENTRIES={len(po)}")
    missing = [record["id"] for record in supportable if not any(("diagnostic", v) in po for v in record["variants"])]
    print(f"MISSING={len(missing)}")
    for name in missing[:12]:
        print(f"MISSING_ID={name}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("coverage", "stats"))
    args = parser.parse_args(argv)
    try:
        upstream = load_upstream()
        verify_checkout(upstream["cache"], upstream["commit"])
        defs = tblgen_records(upstream["cache"])
        if args.command == "coverage":
            return cmd_coverage(upstream, defs)
        return cmd_stats(upstream, defs)
    except InventoryError as exc:
        print(f"INVENTORY_ERROR={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
