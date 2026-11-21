#!/usr/bin/env python3
"""Clang TableGen definitions, format expansion, and clangd inventory assembly."""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections import Counter
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

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
# The fixed LLVM version's largest expansion fits within this cap.
VARIANT_CAP = 16384
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
    return subprocess.run(argv, capture_output=True, text=True, check=False, timeout=timeout,
                          env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})


def verify_checkout(cache: Path, commit: str) -> None:
    if not cache.is_dir():
        raise InventoryError(f"{cache}: llvm-project checkout missing")
    probe = run(["git", "-C", str(cache), "cat-file", "-t", commit])
    if probe.returncode != 0 or probe.stdout.strip() != "commit":
        raise InventoryError(f"{cache}: pinned commit {commit} not present")
    head = run(["git", "-C", str(cache), "rev-parse", "HEAD"])
    if head.returncode != 0 or head.stdout.strip() != commit:
        raise InventoryError(f"{cache}: HEAD {head.stdout.strip()} is not pinned {commit}")


def _find_tblgen() -> str:
    from shutil import which
    found = which("llvm-tblgen") or which("llvm-tblgen-23") or which("llvm-tblgen-18")
    if not found:
        raise InventoryError("llvm-tblgen not found; install llvm (Arch: pacman -S llvm)")
    return found


def tblgen_records(cache: Path, tblgen: str | None = None) -> dict:
    result = run([tblgen or _find_tblgen(), str(cache / TBLGEN_TARGET), "-I", str(cache / TBLGEN_INCLUDE),
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
SIMPLE_MODIFIER_RE = re.compile(r"%%|%(ordinal|human|quoted|objcclass|objcinstance|q)(\d+)")
ARGUMENT_RE = re.compile(r"%%|%([a-z]*)(\d+)")


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


@dataclass(frozen=True)
class Directive:
    before: str
    kind: str
    indexes: tuple[int, ...]
    branches: tuple[str, ...]
    tail: str


@lru_cache(maxsize=16384)
def split_directive(template: str) -> Directive | None:
    match = STRUCTURAL_RE.search(template)
    enum = ENUM_SELECT_RE.search(template)
    if enum and (not match or enum.start() < match.start()):
        match = enum
        kind = "enum_select"
    elif match:
        kind = match.group(1)
    else:
        return None
    end = find_matching_brace(template, match.end() - 1)
    inner = template[match.end():end]
    after = template[end + 1:]
    index, consumed = _take_arg_index(after)
    indexes = [index]
    if kind == "sub":
        while after[consumed:consumed + 1] == ",":
            index, width = _take_arg_index(after[consumed + 1:])
            indexes.append(index)
            consumed += 1 + width
        name = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", inner)
        branches = [name.group(1) if name else inner]
    else:
        branches = split_top_level(inner, "|")
        if kind == "enum_select":
            bodies = []
            for tag in branches:
                start = tag.find("{")
                bodies.append(tag[start + 1:].removesuffix("}") if start >= 0 else "")
            branches = bodies
        elif kind == "plural":
            branches = [clause.partition(":")[2] for clause in branches]
        elif kind == "diff":
            if after[consumed:consumed + 1] != ",":
                raise InventoryError(f"%diff without second index: {template[:60]!r}")
            second, width = _take_arg_index(after[consumed + 1:])
            indexes.append(second)
            consumed += 1 + width
            paired, fallback = branches
            branches = [_substitute_diff_dollars(paired, index, second), fallback]
    return Directive(template[:match.start()], kind, tuple(indexes), tuple(branches), after[consumed:])


def expand_template(template: str, substitutions: dict[str, str], *,
                    track_choices: bool = False, selected: dict | None = None,
                    mapping: tuple[int, ...] = ()) -> list[tuple[str, dict]]:
    """Expand a format or follow the branch choices of its source-language format."""
    use_choices = track_choices or selected is not None

    def walk(text: str, arguments: tuple[int, ...], occurrences: dict) -> list[tuple[str, dict]]:
        def mapped(index: int) -> int:
            return arguments[index] if index < len(arguments) else index

        def renumber(match: re.Match) -> str:
            if match.group(0) == "%%":
                return "%%"
            return f"%{match.group(1)}{mapped(int(match.group(2)))}"

        directive = split_directive(text)
        if not directive:
            return [(ARGUMENT_RE.sub(renumber, text), {})]
        head = ARGUMENT_RE.sub(renumber, directive.before)
        body_args = arguments
        bodies = directive.branches
        if directive.kind == "sub":
            body = substitutions.get(bodies[0])
            if body is None:
                if selected is not None:
                    raise InventoryError(f"Unknown TableGen substitution {bodies[0]!r}")
                return [(text, {})]
            bodies = (body,)
            body_args = tuple(mapped(index) for index in directive.indexes)

        key = None
        if use_choices and directive.kind != "sub":
            indexes = tuple(mapped(index) for index in directive.indexes)
            identity = indexes if directive.kind == "diff" else indexes[0]
            base = (directive.kind, identity, len(bodies))
            occurrence = occurrences.get(base, 0)
            key = (*base, occurrence)
            occurrences = {**occurrences, base: occurrence + 1}
        indexes = (selected[key],) if selected is not None and key is not None else range(len(bodies))
        suffixes = walk(directive.tail, arguments, occurrences)
        result = []
        for index in indexes:
            part_choice = {key: index} if track_choices and key is not None else {}
            for body, choices in walk(bodies[index], body_args, occurrences):
                for suffix, suffix_choices in suffixes:
                    recorded = {**part_choice, **choices, **suffix_choices} if track_choices else {}
                    result.append((head + body + suffix, recorded))
        return result

    return walk(template, mapping, {})


def normalize_template(template: str, substitutions: dict[str, str],
                       mapping: list[int] | None = None) -> list[str]:
    return [text for text, _ in expand_template(template, substitutions, mapping=tuple(mapping or ()))]


def strip_simple_modifiers(text: str) -> str:
    """Rewrite rendering-only modifiers to bare placeholders (%ordinal0 -> %0)."""
    return SIMPLE_MODIFIER_RE.sub(lambda m: f"%{m[2]}" if m[2] else "%%", text)


def expand_plural_suffixes(text: str) -> list[str]:
    """Expand %sN (integer + optional plural s) into both rendered shapes."""
    match = next((m for m in re.finditer(r"%%|%s(\d)(?!\d)", text) if m[1]), None)
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
        source_file = f"clang/include/clang/Basic/{Path(locs[0].rsplit(':', 1)[0]).name}" if locs else TBLGEN_TARGET
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
