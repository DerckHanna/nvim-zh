#!/usr/bin/env python3
"""Sync the Clang toolchain PO catalogs from the source inventory.

The maintenance map (``translations/toolchain/zh_CN.json``) holds reviewed
msgid/msgstr pairs keyed by the diagnostic or check they belong to. The tool
also reuses generic Clang diagnostic translations already reviewed for the
clangd domain when the only difference is the first-letter capitalization
(clangd capitalizes a composed diagnostic; compiler output keeps the TableGen
spelling).

Existing PO entries are preserved. Only missing entries are added and a map
entry overrides an existing msgstr for its exact context/msgid.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_tool as ct  # noqa: E402
import diagnostic_inventory as di  # noqa: E402
from diagnostic_inventory import expand_plural_suffixes, normalize_template, strip_simple_modifiers  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "translations/toolchain/zh_CN.json"
CLANG_INVENTORY = ROOT / "manifests/clang-coverage.json"
CLANGD_INVENTORY = ROOT / "manifests/clangd-coverage.json"
TIDY_INVENTORY = ROOT / "manifests/clang-tidy-coverage.json"
CLANGD_PO = ROOT / "translations/po/zh_CN/clangd.po"
CLANG_PO = ROOT / "translations/po/zh_CN/clang.po"
TIDY_PO = ROOT / "translations/po/zh_CN/clang-tidy.po"

HEADER = """Project-Id-Version: nvim-zh {domain}
PO-Revision-Date: 2026-11-20 16:00+0800
Last-Translator: nvim-zh maintainers
Language-Team: Simplified Chinese
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Language: zh_CN
Content-Transfer-Encoding: 8bit
"""

DIAGNOSTIC_CONTEXTS = {"diagnostic", "note"}
RAW_PLACEHOLDER_RE = re.compile(r"%\d+")


def load_po(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    entries, _ = ct.parse_po(path)
    return entries


def clangd_candidates(obsolete: set[str] | None = None) -> dict[str, dict]:
    """Reusable generic Clang diagnostic entries from the reviewed clangd PO."""
    result: dict[str, dict] = {}
    blocked = obsolete or set()
    for row in load_po(CLANGD_PO):
        context = row.get("msgctxt", "")
        if row["msgid"] in blocked:
            continue
        if context in DIAGNOSTIC_CONTEXTS or context.startswith("-W"):
            result.setdefault(row["msgid"], row)
    return result


def entry(context: str, msgid: str, msgstr: str, references: list[str], priority: bool = False) -> dict:
    return {"msgctxt": context, "msgid": msgid, "msgstr": msgstr,
            "references": references, "priority": priority}


def variant_index(inventory: dict) -> dict[str, list[dict]]:
    result: dict[str, list[dict]] = {}
    for record in inventory["diagnostics"]:
        if record.get("free_text"):
            continue
        for variant in record["variants"]:
            if variant.replace("%0", "").strip() == "" or variant in {"%0", "%1", "%2"}:
                continue
            result.setdefault(variant, []).append(record)
    return result


def _parse_directives(template: str, substitutions: dict[str, str],
                      mapping: list[int] | None = None, occ_counter: dict | None = None) -> list[tuple[str, dict]]:
    """Expand TableGen directives while recording deterministic branch choice keys."""
    if mapping is None:
        mapping = list(range(16))
    if occ_counter is None:
        occ_counter = {}

    def map_index(index: int) -> int:
        return mapping[index] if index < len(mapping) else index

    def literal(text: str) -> str:
        def renumber(placeholder: re.Match) -> str:
            if placeholder.group(0) == "%%":
                return "%%"
            return f"%{placeholder.group(1)}{map_index(int(placeholder.group(2)))}"
        return di.ARGUMENT_RE.sub(renumber, text)

    match = di.STRUCTURAL_RE.search(template)
    enum_match = di.ENUM_SELECT_RE.search(template)
    if enum_match and (not match or enum_match.start() < match.start()):
        open_brace = enum_match.end() - 1
        close_brace = di.find_matching_brace(template, open_brace)
        inner = template[open_brace + 1 : close_brace]
        after = template[close_brace + 1 :]
        index, consumed = di._take_arg_index(after)
        tail = after[consumed:]
        head = literal(template[: enum_match.start()])
        tags = di.split_top_level(inner, "|")
        key_base = ("enum_select", map_index(index), len(tags))
        occ = occ_counter.get(key_base, 0)
        next_occ = {**occ_counter, key_base: occ + 1}
        dkey = (*key_base, occ)
        results = []
        for idx, tag in enumerate(tags):
            open_tag = tag.find("{")
            body = (tag[open_tag + 1 : -1] if open_tag >= 0 and tag.endswith("}")
                    else (tag[open_tag + 1 :] if open_tag >= 0 else ""))
            for b_str, b_choices in _parse_directives(body, substitutions, mapping, dict(next_occ)):
                for t_str, t_choices in _parse_directives(tail, substitutions, mapping, dict(next_occ)):
                    results.append((head + b_str + t_str, {dkey: idx, **b_choices, **t_choices}))
        return results
    if not match:
        return [(literal(template), {})]
    kind = match.group(1)
    open_brace = match.end() - 1
    close_brace = di.find_matching_brace(template, open_brace)
    inner = template[open_brace + 1 : close_brace]
    after = template[close_brace + 1 :]
    head = literal(template[: match.start()])
    if kind == "sub":
        index, consumed = di._take_arg_index(after)
        indexes = [index]
        while after[consumed : consumed + 1] == ",":
            index, width = di._take_arg_index(after[consumed + 1 :])
            indexes.append(index)
            consumed += 1 + width
        name_match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", inner)
        body = substitutions.get(name_match.group(1)) if name_match else None
        if body is None:
            return [(template, {})]
        inner_mapping = [map_index(i) for i in indexes]
        tail = after[consumed:]
        results = []
        for b_str, b_choices in _parse_directives(body, substitutions, inner_mapping, dict(occ_counter)):
            for t_str, t_choices in _parse_directives(tail, substitutions, mapping, dict(occ_counter)):
                results.append((head + b_str + t_str, {**b_choices, **t_choices}))
        return results
    if kind in {"select", "plural"}:
        index, consumed = di._take_arg_index(after)
        tail = after[consumed:]
        items = di.split_top_level(inner, "|")
        key_base = (kind, map_index(index), len(items))
        occ = occ_counter.get(key_base, 0)
        next_occ = {**occ_counter, key_base: occ + 1}
        dkey = (*key_base, occ)
        results = []
        for idx, item in enumerate(items):
            part = item if kind == "select" else item.partition(":")[2]
            for b_str, b_choices in _parse_directives(part, substitutions, mapping, dict(next_occ)):
                for t_str, t_choices in _parse_directives(tail, substitutions, mapping, dict(next_occ)):
                    results.append((head + b_str + t_str, {dkey: idx, **b_choices, **t_choices}))
        return results
    first, consumed = di._take_arg_index(after)
    second, width = di._take_arg_index(after[consumed + 1 :])
    tail = after[consumed + 1 + width :]
    paired, fallback = di.split_top_level(inner, "|")
    key_base = ("diff", (map_index(first), map_index(second)), 2)
    occ = occ_counter.get(key_base, 0)
    next_occ = {**occ_counter, key_base: occ + 1}
    dkey = (*key_base, occ)
    results = []
    for idx, prepared in enumerate((di._substitute_diff_dollars(paired, first, second), fallback)):
        for b_str, b_choices in _parse_directives(prepared, substitutions, mapping, dict(next_occ)):
            for t_str, t_choices in _parse_directives(tail, substitutions, mapping, dict(next_occ)):
                results.append((head + b_str + t_str, {dkey: idx, **b_choices, **t_choices}))
    return results


def _render_with_choices(template: str, substitutions: dict[str, str], choices: dict,
                         mapping: list[int] | None = None, occ_counter: dict | None = None) -> str:
    """Render a Chinese summary template using recorded branch choices from _parse_directives."""
    if mapping is None:
        mapping = list(range(16))
    if occ_counter is None:
        occ_counter = {}

    def map_index(index: int) -> int:
        return mapping[index] if index < len(mapping) else index

    def literal(text: str) -> str:
        def renumber(placeholder: re.Match) -> str:
            if placeholder.group(0) == "%%":
                return "%%"
            return f"%{placeholder.group(1)}{map_index(int(placeholder.group(2)))}"
        return di.ARGUMENT_RE.sub(renumber, text)

    match = di.STRUCTURAL_RE.search(template)
    enum_match = di.ENUM_SELECT_RE.search(template)
    if enum_match and (not match or enum_match.start() < match.start()):
        open_brace = enum_match.end() - 1
        close_brace = di.find_matching_brace(template, open_brace)
        inner = template[open_brace + 1 : close_brace]
        after = template[close_brace + 1 :]
        index, consumed = di._take_arg_index(after)
        tail = after[consumed:]
        head = literal(template[: enum_match.start()])
        tags = di.split_top_level(inner, "|")
        key_base = ("enum_select", map_index(index), len(tags))
        occ = occ_counter.get(key_base, 0)
        next_occ = {**occ_counter, key_base: occ + 1}
        tag = tags[choices[(*key_base, occ)]]
        open_tag = tag.find("{")
        body = (tag[open_tag + 1 : -1] if open_tag >= 0 and tag.endswith("}")
                else (tag[open_tag + 1 :] if open_tag >= 0 else ""))
        return (head
                + _render_with_choices(body, substitutions, choices, mapping, dict(next_occ))
                + _render_with_choices(tail, substitutions, choices, mapping, dict(next_occ)))
    if not match:
        return literal(template)
    kind = match.group(1)
    open_brace = match.end() - 1
    close_brace = di.find_matching_brace(template, open_brace)
    inner = template[open_brace + 1 : close_brace]
    after = template[close_brace + 1 :]
    head = literal(template[: match.start()])
    if kind == "sub":
        index, consumed = di._take_arg_index(after)
        indexes = [index]
        while after[consumed : consumed + 1] == ",":
            index, width = di._take_arg_index(after[consumed + 1 :])
            indexes.append(index)
            consumed += 1 + width
        name_match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", inner)
        body = substitutions.get(name_match.group(1)) if name_match else None
        if body is None:
            raise ValueError(f"Unknown %sub{{{inner}}}")
        inner_mapping = [map_index(i) for i in indexes]
        tail = after[consumed:]
        return (head
                + _render_with_choices(body, substitutions, choices, inner_mapping, dict(occ_counter))
                + _render_with_choices(tail, substitutions, choices, mapping, dict(occ_counter)))
    if kind in {"select", "plural"}:
        index, consumed = di._take_arg_index(after)
        tail = after[consumed:]
        items = di.split_top_level(inner, "|")
        key_base = (kind, map_index(index), len(items))
        occ = occ_counter.get(key_base, 0)
        next_occ = {**occ_counter, key_base: occ + 1}
        picked = items[choices[(*key_base, occ)]]
        part = picked if kind == "select" else picked.partition(":")[2]
        return (head
                + _render_with_choices(part, substitutions, choices, mapping, dict(next_occ))
                + _render_with_choices(tail, substitutions, choices, mapping, dict(next_occ)))
    first, consumed = di._take_arg_index(after)
    second, width = di._take_arg_index(after[consumed + 1 :])
    tail = after[consumed + 1 + width :]
    paired, fallback = di.split_top_level(inner, "|")
    key_base = ("diff", (map_index(first), map_index(second)), 2)
    occ = occ_counter.get(key_base, 0)
    next_occ = {**occ_counter, key_base: occ + 1}
    prepared = (di._substitute_diff_dollars(paired, first, second), fallback)[choices[(*key_base, occ)]]
    return (head
            + _render_with_choices(prepared, substitutions, choices, mapping, dict(next_occ))
            + _render_with_choices(tail, substitutions, choices, mapping, dict(next_occ)))


def expand_summaries(clang_section: dict) -> dict[str, dict[str, str]]:
    """Expand multi-variant summary translations from translations/toolchain/zh_CN.json."""
    subs = clang_section.get("substitutions", {})
    en_subs = {name: item["en"] for name, item in subs.items()}
    zh_subs = {name: item["zh"] for name, item in subs.items()}
    expanded: dict[str, dict[str, str]] = {}
    for summary, target in clang_section.get("summaries", {}).items():
        if isinstance(target, dict):
            expanded[summary] = target
            continue
        pairs: dict[str, str] = {}
        for raw_en, choices in _parse_directives(summary, en_subs):
            raw_zh = _render_with_choices(target, zh_subs, choices)
            zh_text = strip_simple_modifiers(raw_zh)
            for en_variant in expand_plural_suffixes(strip_simple_modifiers(raw_en)):
                pairs.setdefault(en_variant, zh_text)
        expanded[summary] = pairs
    return expanded


def _default_clang_context(record: dict) -> str:
    return ("driver" if record["component"] == "Driver" else
            "note" if record["severity"] == "note" else "diagnostic")


def build_clang(clang_section: dict, obsolete: set[str]) -> list[dict]:
    inventory = json.loads(CLANG_INVENTORY.read_text(encoding="utf-8"))
    index = variant_index(inventory)
    by_id = {record["id"]: record for record in inventory["diagnostics"]}
    map_entries = clang_section.get("diagnostic", {})
    summaries = expand_summaries(clang_section)
    overrides = clang_section.get("overrides", {})
    reuse = clangd_candidates(obsolete)
    out: dict[tuple[str, str], dict] = {}

    def add(msgid: str, msgstr: str, record: dict, context: str, priority: bool) -> None:
        reference = f"{record['source']}:{record['line']}"
        key = context, msgid
        current = out.get(key)
        if current:
            if current["msgstr"] != msgstr:
                if priority and not current["priority"]:
                    out[key] = entry(context, msgid, msgstr, sorted(set(current["references"]) | {reference}), True)
                    return
                if not priority:
                    current["references"] = sorted(set(current["references"]) | {reference})
                    return
                raise SystemExit(f"clang: conflicting translations for {key!r}")
            current["references"] = sorted(set(current["references"]) | {reference})
            if priority:
                current["priority"] = True
            return
        out[key] = entry(context, msgid, msgstr, [reference], priority)

    for record in inventory["diagnostics"]:
        if record.get("free_text") or len(record["variants"]) <= 1:
            continue
        pairs = summaries.get(record["summary"])
        if not pairs:
            continue
        context = _default_clang_context(record)
        for variant in record["variants"]:
            if not variant or variant in obsolete or RAW_PLACEHOLDER_RE.fullmatch(variant):
                continue
            if variant in pairs:
                add(variant, pairs[variant], record, context, False)

    for msgid, info in map_entries.items():
        if msgid in obsolete:
            continue
        record = by_id.get(info["diagnostic"])
        variant = info.get("source_variant", msgid)
        if record is None or variant not in record["variants"] or record["free_text"]:
            raise SystemExit(f"clang: map msgid not found in {info['diagnostic']}: {variant!r}")
        context = info.get("context") or _default_clang_context(record)
        add(msgid, info["msgstr"], record, context, True)
        if info.get("unlocated"):
            add(msgid, info["msgstr"], record, "unlocated", True)
        if info.get("substitution_diagnostic"):
            add(msgid, info["msgstr"], record, "substitution_diagnostic", True)
        if "runtime" in info:
            rendered = info["runtime"]
            add(rendered["msgid"], rendered["msgstr"], record, context, True)

    for record in inventory["diagnostics"]:
        if record.get("free_text") or len(record["variants"]) != 1:
            continue
        variant = record["variants"][0]
        if not variant or variant in obsolete or RAW_PLACEHOLDER_RE.fullmatch(variant):
            continue
        info = map_entries.get(variant)
        if info and info.get("context") != "template_arity":
            context = _default_clang_context(record)
            if (context, variant) not in out:
                add(variant, info["msgstr"], record, context, True)

    for context, items in overrides.items():
        for msgid, msgstr in items.items():
            if msgid in obsolete:
                continue
            matches = index.get(msgid, [])
            matching = [r for r in matches if _default_clang_context(r) == context] or matches
            if not matching:
                raise SystemExit(f"clang: override msgid not found in inventory: {(context, msgid)!r}")
            for record in matching:
                add(msgid, msgstr, record, context, True)

    lower_map = {msgid.lower() for _, msgid in out}
    for msgid, source in reuse.items():
        if msgid in obsolete or msgid.lower() in lower_map:
            continue
        # The clangd catalog may spell some arguments as named placeholders
        # (for example `{statement}`) while the compiler template uses `%N`.
        # Both are valid matcher templates for identical rendered text, so the
        # reviewed entry is reused verbatim instead of re-authored.
        options = tuple(variant for variant in (msgid, msgid[:1].lower() + msgid[1:]) if variant in index)
        for variant in options:
            for record in index[variant]:
                add(variant, source["msgstr"], record, _default_clang_context(record), False)
    return sorted(out.values(), key=lambda item: (item["msgctxt"], item["msgid"]))


def build_clangd(mapping: dict, clang_entries: list[dict], existing_clangd: list[dict]) -> list[dict]:
    clangd_section = mapping.get("clangd", {})
    obsolete = set(clangd_section.get("obsolete", []))
    overrides = clangd_section.get("overrides", {})
    map_entries = mapping.get("clang", {}).get("diagnostic", {})
    source = json.loads(CLANGD_INVENTORY.read_text(encoding="utf-8"))
    by_id = {item["id"]: item for item in source["diagnostics"]}
    clang_lookup = {(row["msgctxt"], row["msgid"]): row["msgstr"]
                    for row in clang_entries if row["msgctxt"] in {"diagnostic", "note", "template_arity"}}
    existing_lookup = {(row.get("msgctxt", ""), row["msgid"]): row["msgstr"] for row in existing_clangd}
    out: dict[tuple[str, str], dict] = {}

    def add(context: str, msgid: str, msgstr: str, reference: str, priority: bool) -> None:
        key = context, msgid
        current = out.get(key)
        if current:
            current["references"] = sorted(set(current["references"]) | {reference})
            if priority:
                current["msgstr"] = msgstr
                current["priority"] = True
            return
        out[key] = entry(context, msgid, msgstr, [reference], priority)

    for msgid, info in map_entries.items():
        if not info.get("clangd") or msgid in obsolete:
            continue
        record = by_id[info["diagnostic"]]
        if msgid not in record["variants"]:
            raise SystemExit(f"clangd: source variant missing in {info['diagnostic']}: {msgid!r}")
        reference = f"{record['source']}:{record['line']}"
        code = record["id"].removeprefix("err_")
        contexts = [f"-W{group}" for group in record["groups"]] or [code]
        if record["severity"] == "note":
            contexts.append("related_diagnostic")
        if info.get("substitution_diagnostic"):
            contexts.append("substitution_diagnostic")
        original = msgid[:1].upper() + msgid[1:]
        for context in contexts:
            add(context, original, info["msgstr"], reference, False)

    for record in source["diagnostics"]:
        if record.get("free_text"):
            continue
        cd_ctx = "related_diagnostic" if record["severity"] == "note" else "diagnostic"
        c_ctx = "note" if record["severity"] == "note" else "diagnostic"
        reference = f"{record['source']}:{record['line']}"
        for variant in record["variants"]:
            if not variant or variant in obsolete or RAW_PLACEHOLDER_RE.fullmatch(variant):
                continue
            original = variant[:1].upper() + variant[1:]
            override = overrides.get(cd_ctx, {}).get(original)
            if override is not None:
                add(cd_ctx, original, override, reference, True)
            elif (c_ctx, variant) in clang_lookup:
                add(cd_ctx, original, clang_lookup[(c_ctx, variant)], reference, False)
            elif c_ctx == "diagnostic" and ("template_arity", variant) in clang_lookup:
                add(cd_ctx, original, clang_lookup[("template_arity", variant)], reference, False)
            elif (cd_ctx, original) in existing_lookup:
                add(cd_ctx, original, existing_lookup[(cd_ctx, original)], reference, False)
            else:
                raise SystemExit(f"clangd: missing translation for {(cd_ctx, original)!r}")

    return sorted(out.values(), key=lambda item: (item["msgctxt"], item["msgid"]))


def build_frontend(map_entries: dict) -> list[dict]:
    source = json.loads(CLANG_INVENTORY.read_text(encoding="utf-8"))
    inventory = {item["id"]: item for item in source["frontend_messages"]}
    out = []
    for name, msgstr in map_entries.items():
        item = inventory[name]
        reference = f"{item['source']}:{item['line']}"
        out.append(entry(item["interface"], item["variants"][0], msgstr, [reference], True))
    return out


def build_tidy(map_checks: dict) -> list[dict]:
    inventory = json.loads(TIDY_INVENTORY.read_text(encoding="utf-8"))
    index: dict[tuple[str, str, bool], tuple[dict, dict]] = {}
    checks = [*inventory["checks"], *inventory["analyzer_checkers"]]
    for check in checks:
        for message in check["messages"]:
            index[(check["name"], message["message"], message["note"])] = (check, message)
    out: dict[tuple[str, str], dict] = {}
    for check_name, entries in map_checks.items():
        if check_name == "fix_note":
            return_path = "clang/include/clang/Basic/DiagnosticFrontendKinds.td"
            source = json.loads(CLANG_INVENTORY.read_text(encoding="utf-8"))
            note = next(row for row in source["diagnostics"] if row["id"] == "note_fixit_applied")
            for msgid, info in entries.items():
                if msgid != note["summary"]:
                    raise SystemExit(f"clang-tidy: unexpected fix application note: {msgid!r}")
                out[(check_name, msgid)] = entry(check_name, msgid, info["msgstr"],
                                                 [f"{return_path}:{note['line']}"], True)
            continue
        if check_name not in {check["name"] for check in checks}:
            raise SystemExit(f"clang-tidy: unknown check {check_name!r}")
        for msgid, info in entries.items():
            source_message = info.get("source_variant", msgid)
            note = bool(info.get("note"))
            verified = index.get((check_name, source_message, note))
            if verified is None:
                raise SystemExit(f"clang-tidy: {check_name}: msgid not in inventory: {msgid!r}")
            if source_message != msgid:
                variants = {variant for shape in normalize_template(source_message, {})
                            for variant in expand_plural_suffixes(strip_simple_modifiers(shape))}
                if msgid not in variants:
                    raise SystemExit(f"clang-tidy: {check_name}: invalid rendered shape: {msgid!r}")
            check, message = verified
            context = check_name + ("/note" if note else "")
            out[(context, msgid)] = entry(context, msgid, info["msgstr"],
                                         [f"{message.get('source', check['source'])}:{message['line']}"], True)
            if info.get("also_note"):
                _, note_message = index[(check_name, source_message, True)]
                context = check_name + "/note"
                out[(context, msgid)] = entry(context, msgid, info["msgstr"],
                                             [f"{note_message.get('source', check['source'])}:{note_message['line']}"], True)
    return sorted(out.values(), key=lambda item: (item["msgctxt"], item["msgid"]))


def po_quote(value: str) -> str:
    escaped = value.replace('\\', '\\\\').replace('"', '\\"')
    escaped = escaped.replace('\n', '\\n').replace('\t', '\\t')
    return escaped


def render(domain: str, entries: list[dict]) -> str:
    lines = [f'msgid ""', f'msgstr ""']
    for line in HEADER.format(domain=domain).splitlines():
        lines.append(f'"{line}\\n"')
    lines.append("")
    return "\n".join(lines) + render_entries(entries)


def render_entries(entries: list[dict]) -> str:
    lines = [""]
    for item in entries:
        for reference in sorted(item["references"]):
            lines.append(f"#: {reference}")
        lines.append(f'msgctxt "{po_quote(item["msgctxt"])}"')
        lines.append(f'msgid "{po_quote(item["msgid"])}"')
        lines.append(f'msgstr "{po_quote(item["msgstr"])}"')
        lines.append("")
    return "\n".join(lines)


def refresh(existing: list[dict], generated: list[dict], obsolete: set[str] | None = None) -> list[dict]:
    """Keep every existing entry; add missing ones; map values win."""
    blocked = obsolete or set()
    moved = {item["msgid"] for item in generated
             if item["msgctxt"] in {"driver", "note", "err_expected_after", "template_arity"}}
    result = [dict(item) for item in existing
              if item["msgid"] not in blocked
              and (item.get("msgctxt") != "diagnostic" or item["msgid"] not in moved)]
    for item in result:
        item["references"] = [re.sub(r":([0-9]+):\1$", r":\1", source)
                              for source in item.get("references", [])]
    keys = {(item.get("msgctxt", ""), item["msgid"]): index for index, item in enumerate(result)}
    for item in generated:
        key = (item["msgctxt"], item["msgid"])
        if key in keys:
            current = result[keys[key]]
            if item.get("priority"):
                current["msgstr"] = item["msgstr"]
            current["references"] = sorted(set(current.get("references", [])) | set(item["references"]))
        else:
            keys[key] = len(result)
            result.append(dict(item))
    return sorted(result, key=lambda item: (item.get("msgctxt", ""), item["msgid"]))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "sync"))
    args = parser.parse_args(argv)
    mapping = json.loads(MAP.read_text(encoding="utf-8"))
    clang_section = mapping.get("clang", {})
    obsolete = set(mapping.get("clangd", {}).get("obsolete", []))
    clang = build_clang(clang_section, obsolete)
    clang.extend(build_frontend(clang_section.get("frontend", {})))
    tidy = build_tidy(mapping.get("clang-tidy", {}))
    existing_clangd = load_po(CLANGD_PO)
    clangd = build_clangd(mapping, clang, existing_clangd)
    catalogs = (("clang", CLANG_PO, clang), ("clangd", CLANGD_PO, clangd), ("clang-tidy", TIDY_PO, tidy))
    if args.command == "sync":
        for domain, path, entries in catalogs:
            existing = load_po(path)
            merged = refresh(existing, entries, obsolete)
            text = render(domain, merged)
            ct.atomic_write_text(path, text)
            print(f"TOOLCHAIN_CATALOG={domain} entries={len(merged)} added={len(merged) - len(existing)}")
    else:
        for domain, path, entries in catalogs:
            if not path.is_file():
                raise SystemExit(f"missing {path}; run sync")
            if path.read_text(encoding="utf-8") != render(domain, refresh(load_po(path), entries, obsolete)):
                raise SystemExit(f"{path} is stale; run sync")
            print(f"TOOLCHAIN_CATALOG_CHECK={domain} entries={len(load_po(path))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
