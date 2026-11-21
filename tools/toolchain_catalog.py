#!/usr/bin/env python3
"""Generate the toolchain PO catalogs from fixed inventories and reviewed translations."""

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
CLANG_PO = ROOT / "translations/po/zh_CN/clang.po"

HEADER = """Project-Id-Version: nvim-zh {domain}
PO-Revision-Date: 2026-11-20 16:00+0800
Last-Translator: nvim-zh maintainers
Language-Team: Simplified Chinese
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Language: zh_CN
Content-Transfer-Encoding: 8bit
"""

RAW_PLACEHOLDER_RE = re.compile(r"%\d+")


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
        for raw_en, choices in di.expand_template(summary, en_subs, track_choices=True):
            [(raw_zh, _)] = di.expand_template(target, zh_subs, selected=choices)
            zh_text = strip_simple_modifiers(raw_zh)
            for en_variant in expand_plural_suffixes(strip_simple_modifiers(raw_en)):
                pairs.setdefault(en_variant, zh_text)
        expanded[summary] = pairs
    return expanded


def _default_clang_context(record: dict) -> str:
    return ("driver" if record["component"] == "Driver" else
            "note" if record["severity"] == "note" else "diagnostic")


def build_clang(clang_section: dict, obsolete: set[str], inventory: dict) -> list[dict]:
    index = variant_index(inventory)
    by_id = {record["id"]: record for record in inventory["diagnostics"]}
    map_entries = clang_section.get("diagnostic", {})
    summaries = expand_summaries(clang_section)
    overrides = clang_section.get("overrides", {})
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

    return sorted(out.values(), key=lambda item: (item["msgctxt"], item["msgid"]))


def build_clangd(mapping: dict, clang_entries: list[dict], source: dict) -> list[dict]:
    clangd_section = mapping.get("clangd", {})
    obsolete = set(clangd_section.get("obsolete", []))
    overrides = clangd_section.get("overrides", {})
    map_entries = mapping.get("clang", {}).get("diagnostic", {})
    by_id = {item["id"]: item for item in source["diagnostics"]}
    clang_lookup = {(row["msgctxt"], row["msgid"]): row["msgstr"]
                    for row in clang_entries if row["msgctxt"] in {"diagnostic", "note", "template_arity"}}
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
            else:
                raise SystemExit(f"clangd: missing translation for {(cd_ctx, original)!r}")

    return sorted(out.values(), key=lambda item: (item["msgctxt"], item["msgid"]))


def build_frontend(map_entries: dict, source: dict) -> list[dict]:
    inventory = {item["id"]: item for item in source["frontend_messages"]}
    out = []
    for name, msgstr in map_entries.items():
        item = inventory[name]
        reference = f"{item['source']}:{item['line']}"
        out.append(entry(item["interface"], item["variants"][0], msgstr, [reference], True))
    return out


def build_tidy(map_checks: dict, inventory: dict, clang: dict) -> list[dict]:
    index: dict[tuple[str, str, bool], tuple[dict, dict]] = {}
    checks = [*inventory["checks"], *inventory["analyzer_checkers"]]
    for check in checks:
        for message in check["messages"]:
            index[(check["name"], message["message"], message["note"])] = (check, message)
    out: dict[tuple[str, str], dict] = {}
    names = {check["name"] for check in checks}
    for check_name, entries in map_checks.items():
        if check_name == "fix_note":
            return_path = "clang/include/clang/Basic/DiagnosticFrontendKinds.td"
            note = next(row for row in clang["diagnostics"] if row["id"] == "note_fixit_applied")
            for msgid, info in entries.items():
                if msgid != note["summary"]:
                    raise SystemExit(f"clang-tidy: unexpected fix application note: {msgid!r}")
                out[(check_name, msgid)] = entry(check_name, msgid, info["msgstr"],
                                                 [f"{return_path}:{note['line']}"], True)
            continue
        if check_name not in names:
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


def merge_reviewed(domain: str, generated: list[dict], reviewed: list[dict]) -> list[dict]:
    rows = {(row["msgctxt"], row["msgid"]): row for row in generated}
    seen = set()
    for row in reviewed:
        key = row["context"], row["msgid"]
        if key in seen:
            raise ValueError(f"{domain}: duplicate reviewed entry {key!r}")
        seen.add(key)
        previous = rows.get(key)
        text = row.get("msgstr")
        references = row.get("references", [])
        if previous is None:
            if not text:
                raise ValueError(f"{domain}: reviewed references without an entry for {key!r}")
            rows[key] = entry(*key, text, references)
            continue
        if text is not None:
            previous["msgstr"] = text
        if references:
            previous["references"] = sorted(set(previous["references"]) | set(references))
    return [rows[key] for key in sorted(rows)]


def generate(inventory_path: Path, mapping_path: Path = MAP) -> dict[str, list[dict]]:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    clang_section = mapping["clang"]
    obsolete = set(mapping["clangd"].get("obsolete", []))
    inventory = inventory_rows(inventory_path, "clang")
    clang = build_clang(clang_section, obsolete, inventory)
    clang.extend(build_frontend(clang_section.get("frontend", {}), inventory))
    generated = {"clang": clang,
                 "clangd": build_clangd(mapping, clang, inventory_rows(inventory_path, "clangd")),
                 "clang-tidy": build_tidy(mapping["clang-tidy"], inventory_rows(inventory_path, "clang-tidy"), inventory)}
    return {domain: merge_reviewed(domain, rows, mapping["reviewed"][domain]) for domain, rows in generated.items()}


def verify_po(path: Path, rendered: str) -> None:
    if not path.is_file() or path.read_bytes() != rendered.encode("utf-8"):
        raise ct.CatalogError(f"{path} is stale; run tools/toolchain_catalog.py sync")


def inventory_path(directory: Path, domain: str) -> Path:
    return directory / f"{domain}-coverage.json"


def inventory_rows(directory: Path, domain: str) -> dict:
    return json.loads(inventory_path(directory, domain).read_text(encoding="utf-8"))


def semantic_snapshot(root: Path) -> tuple[dict, dict]:
    if not root.is_dir():
        raise ValueError(f"{root}: checkout directory is missing")
    messages, translations = {}, {}
    for domain in ("clang", "clangd", "clang-tidy"):
        inventory = inventory_path(root / "manifests", domain)
        source = inventory_rows(inventory.parent, domain) if inventory.is_file() else {}
        references = {}
        for record in source.get("diagnostics", []) + source.get("frontend_messages", []):
            key = domain, record["id"]
            messages[key] = sorted(record["variants"])
            reference = f"{record['source']}:{record['line']}"
            references.setdefault(reference, set()).add(record["id"])
        for check in source.get("checks", []) + source.get("analyzer_checkers", []):
            messages[domain, check["name"]] = sorted(set(
                row["message"] for row in check.get("messages", [])
            ))
        po = root / "translations/po/zh_CN" / f"{domain}.po"
        if not po.is_file():
            continue
        entries, _ = ct.parse_po(po)
        for row in entries:
            context = row.get("msgctxt", "")
            ids = set().union(*(references.get(ref, set()) for ref in row["references"]))
            if domain == "clang-tidy" and (domain, context.removesuffix("/note")) in messages:
                ids.add(context.removesuffix("/note"))
            for id in ids or {""}:
                key = domain, id, context, row["msgid"]
                translations.setdefault(key, set()).add(row["msgstr"])
    return messages, translations


def semantic_diff(before: Path, after: Path) -> list[dict]:
    old_messages, old_translations = semantic_snapshot(before)
    messages, translations = semantic_snapshot(after)
    rows = []
    for key in sorted(old_messages.keys() | messages.keys()):
        old, new = old_messages.get(key), messages.get(key)
        if old != new:
            kind = "source_added" if old is None else "source_removed" if new is None else "source_changed"
            rows.append(dict(domain=key[0], id=key[1], kind=kind, before=old, after=new))
    for key in sorted(old_translations.keys() | translations.keys()):
        old, new = sorted(old_translations.get(key, ())), sorted(translations.get(key, ()))
        if old != new:
            kind = "translation_ambiguous" if len(new) > 1 else (
                "translation_added" if not old else "translation_removed" if not new else "translation_changed"
            )
            rows.append(dict(domain=key[0], id=key[1], context=key[2], msgid=key[3], kind=kind,
                             before=old, after=new))
    return rows


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "sync", "diff"))
    parser.add_argument("--output", type=Path, help="write or check generated PO in this directory")
    parser.add_argument("--inventory", type=Path, default=CLANG_INVENTORY.parent)
    parser.add_argument("--before", type=Path, help="checkout containing the previous inventories and PO")
    parser.add_argument("--after", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.command == "diff":
        if not args.before:
            parser.error("diff requires --before")
        report = json.dumps(semantic_diff(args.before, args.after), ensure_ascii=False, indent=2) + "\n"
        if args.output:
            ct.atomic_write_text(args.output, report)
        else:
            print(report, end="")
        return 0
    generated = generate(args.inventory)
    if args.command == "check":
        ct.builtin_sources(ROOT, optional=True)
        checked = ct.check(CLANG_PO.parent, ROOT / "translations/glossary/zh_CN.toml")
        print(f'CATALOG_CHECK=PASS domains={checked["domains"]} entries={checked["entries"]}')
    elif args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    for domain, entries in generated.items():
        path = (args.output or CLANG_PO.parent) / f"{domain}.po"
        rendered = render(domain, entries)
        if args.command == "sync":
            ct.atomic_write_text(path, rendered)
            print(f"TOOLCHAIN_CATALOG={domain} entries={len(entries)}")
        else:
            verify_po(path, rendered)
            print(f"TOOLCHAIN_CATALOG_CHECK={domain} entries={len(entries)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
