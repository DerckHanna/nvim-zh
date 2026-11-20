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

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "translations/toolchain/zh_CN.json"
CLANG_INVENTORY = ROOT / "manifests/clang-coverage.json"
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


def load_po(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    entries, _ = ct.parse_po(path)
    return entries


def clangd_candidates() -> dict[str, dict]:
    """Reusable generic Clang diagnostic entries from the reviewed clangd PO."""
    result: dict[str, dict] = {}
    for entry in load_po(CLANGD_PO):
        context = entry.get("msgctxt", "")
        if context in DIAGNOSTIC_CONTEXTS or context.startswith("-W"):
            result.setdefault(entry["msgid"], entry)
    return result


def entry(context: str, msgid: str, msgstr: str, references: list[str], priority: bool = False) -> dict:
    return {"msgctxt": context, "msgid": msgid, "msgstr": msgstr,
            "references": references, "priority": priority}


def variant_index(inventory: dict) -> dict[str, dict]:
    result = {}
    for record in inventory["diagnostics"]:
        if record.get("free_text"):
            continue
        for variant in record["variants"]:
            if variant.replace("%0", "").strip() == "" or variant in {"%0", "%1", "%2"}:
                continue
            result.setdefault(variant, record)
    return result


def build_clang(map_entries: dict) -> list[dict]:
    inventory = json.loads(CLANG_INVENTORY.read_text(encoding="utf-8"))
    index = variant_index(inventory)
    by_id = {record["id"]: record for record in inventory["diagnostics"]}
    reuse = clangd_candidates()
    out: dict[tuple[str, str], dict] = {}

    def add(msgid: str, msgstr: str, record: dict, context: str) -> None:
        reference = f"{record['source']}:{record['line']}"
        key = context, msgid
        current = out.get(key)
        if current and current["msgstr"] != msgstr:
            raise SystemExit(f"clang: conflicting translations for {msgid!r}")
        out[key] = entry(context, msgid, msgstr, [reference], True)

    for msgid, info in map_entries.items():
        record = by_id.get(info["diagnostic"])
        variant = info.get("source_variant", msgid)
        if record is None or variant not in record["variants"] or record["free_text"]:
            raise SystemExit(f"clang: map msgid not found in {info['diagnostic']}: {variant!r}")
        context = info.get("context") or ("driver" if record["component"] == "Driver" else
                                        "note" if record["severity"] == "note" else "diagnostic")
        add(msgid, info["msgstr"], record, context)
        if "runtime" in info:
            rendered = info["runtime"]
            add(rendered["msgid"], rendered["msgstr"], record, context)

    lower_map = {msgid.lower() for _, msgid in out}
    for msgid, source in reuse.items():
        if msgid.lower() in lower_map:
            continue
        # The clangd catalog may spell some arguments as named placeholders
        # (for example `{statement}`) while the compiler template uses `%N`.
        # Both are valid matcher templates for identical rendered text, so the
        # reviewed entry is reused verbatim instead of re-authored.
        options = tuple(variant for variant in (msgid, msgid[:1].lower() + msgid[1:]) if variant in index)
        for variant in options:
            record = index[variant]
            context = ("driver" if record["component"] == "Driver" else
                       "note" if record["severity"] == "note" else "diagnostic")
            add(variant, source["msgstr"], record, context)
    return sorted(out.values(), key=lambda item: (item["msgctxt"], item["msgid"]))


def build_tidy(map_checks: dict) -> list[dict]:
    inventory = json.loads(TIDY_INVENTORY.read_text(encoding="utf-8"))
    index: dict[tuple[str, str], dict] = {}
    for check in inventory["checks"]:
        for message in check["messages"]:
            index[(check["name"], message["message"])] = (check, message)
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
        if check_name not in {check["name"] for check in inventory["checks"]}:
            raise SystemExit(f"clang-tidy: unknown check {check_name!r}")
        for msgid, info in entries.items():
            verified = index.get((check_name, msgid))
            if verified is None:
                raise SystemExit(f"clang-tidy: {check_name}: msgid not in inventory: {msgid!r}")
            check, message = verified
            context = check_name + ("/note" if info.get("note") else "")
            out[(context, msgid)] = entry(context, msgid, info["msgstr"],
                                         [f"{check['source']}:{message['line']}"], True)
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
    for item in entries:
        for reference in sorted(item["references"]):
            lines.append(f"#: {reference}")
        lines.append(f'msgctxt "{po_quote(item["msgctxt"])}"')
        lines.append(f'msgid "{po_quote(item["msgid"])}"')
        lines.append(f'msgstr "{po_quote(item["msgstr"])}"')
        lines.append("")
    return "\n".join(lines)


def refresh(existing: list[dict], generated: list[dict]) -> list[dict]:
    """Keep every existing entry; add missing ones; map values win."""
    moved = {item["msgid"] for item in generated if item["msgctxt"] in {"driver", "note", "err_expected_after"}}
    result = [dict(item) for item in existing
              if item.get("msgctxt") != "diagnostic" or item["msgid"] not in moved]
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
    clang = build_clang(mapping.get("clang", {}).get("diagnostic", {}))
    tidy = build_tidy(mapping.get("clang-tidy", {}))
    if args.command == "sync":
        for domain, path, entries in (("clang", CLANG_PO, clang), ("clang-tidy", TIDY_PO, tidy)):
            existing = load_po(path)
            merged = refresh(existing, entries)
            text = render(domain, merged)
            ct.atomic_write_text(path, text)
            print(f"TOOLCHAIN_CATALOG={domain} entries={len(merged)} added={len(merged) - len(existing)}")
    else:
        for domain, path, entries in (("clang", CLANG_PO, clang), ("clang-tidy", TIDY_PO, tidy)):
            if not path.is_file():
                raise SystemExit(f"missing {path}; run sync")
            if path.read_text(encoding="utf-8") != render(domain, refresh(load_po(path), entries)):
                raise SystemExit(f"{path} is stale; run sync")
            print(f"TOOLCHAIN_CATALOG_CHECK={domain} entries={len(load_po(path))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
