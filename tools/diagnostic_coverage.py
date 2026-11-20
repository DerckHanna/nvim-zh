#!/usr/bin/env python3
"""Check the clangd translation coverage against the pinned upstream inventory.

Reads manifests/clangd-coverage.json (produced by tools/diagnostic_inventory.py)
and the clangd PO catalog, then reports:

  * upstream fixed templates that have a translation
  * upstream fixed templates without a translation (coverage gaps)
  * diagnostics whose templates cannot be translated by the display engine
    (runtime free text such as #error bodies, pragma messages, apinotes)
  * runtime free text entries that intentionally keep the upstream wording

Exit status is non-zero when a required check fails; the --report flag writes a
machine-readable JSON summary next to the coverage manifest.

Usage:
    python3 tools/diagnostic_coverage.py            # summary on stdout
    python3 tools/diagnostic_coverage.py --report   # also refresh the report
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COVERAGE = ROOT / "manifests/clangd-coverage.json"
PO = ROOT / "translations/po/zh_CN/clangd.po"
REPORT = ROOT / "manifests/clangd-coverage-report.json"

# Diagnostics whose whole message is user supplied text: clang renders the
# argument verbatim (clang/lib/Basic/Diagnostic.cpp FormatDiagnostic treats a
# bare "%0" message as an external string). They must stay untranslated.
RUNTIME_FREE_TEXT = {
    "err_apinotes_message", "note_apinotes_message", "warn_apinotes_message",
    "err_diagnose_if_succeeded", "warn_diagnose_if_succeeded",
    "err_inline_ms_asm_parsing", "err_pp_hash_error", "pp_hash_warning",
    "err_pragma_message", "warn_pragma_message",
    "note_partial_spec_not_more_specialized_than_primary",
}

# Templates whose literal spine is shorter than the engine threshold; they are
# not matched at runtime and stay upstream text on purpose.
SHORT_SPINE_LIMIT = 8


def po_entries(path: Path) -> dict[tuple[str, str], str]:
    entries: dict[tuple[str, str], str] = {}
    context = msgid = msgstr = None
    active = None

    def finish():
        nonlocal context, msgid, msgstr
        if msgid is not None and msgstr is not None:
            entries[(context or "", msgid)] = msgstr
        context = msgid = msgstr = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r'^(msgctxt|msgid|msgstr)\s+"(.*)"$', line)
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


def spine(text: str) -> int:
    return len(re.sub(r"%\d", "", text))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="write the JSON report")
    parser.add_argument("--max-report", type=int, default=40, help="sample size in the report")
    args = parser.parse_args(argv)
    if not COVERAGE.is_file():
        print(f"COVERAGE_ERROR={COVERAGE} missing; run tools/diagnostic_inventory.py coverage", file=sys.stderr)
        return 1
    coverage = json.loads(COVERAGE.read_text(encoding="utf-8"))
    entries = po_entries(PO)
    translated_templates = {msgid for (context, msgid) in entries if context == "diagnostic" and msgid}

    covered, gaps, runtime_free, short_spine = [], [], [], []
    for record in coverage["diagnostics"]:
        variants = record["variants"]
        if record["id"] in RUNTIME_FREE_TEXT:
            runtime_free.append({"id": record["id"], "source": f'{record["source"]}:{record["line"]}',
                                 "reason": "message body is user supplied text"})
            continue
        usable = [v for v in variants if spine(v) >= SHORT_SPINE_LIMIT]
        if not usable:
            short_spine.append({"id": record["id"], "source": f'{record["source"]}:{record["line"]}',
                                 "variants": variants,
                                 "reason": "literal spine shorter than the engine match threshold"})
            continue
        hit = [v for v in usable if v in translated_templates]
        if hit:
            covered.append({"id": record["id"], "source": f'{record["source"]}:{record["line"]}',
                            "severity": record["severity"], "component": record["component"],
                            "groups": record["groups"], "variants_total": len(variants),
                            "variants_translated": len(hit)})
        else:
            gaps.append({"id": record["id"], "source": f'{record["source"]}:{record["line"]}',
                         "severity": record["severity"], "component": record["component"],
                         "groups": record["groups"], "variants": variants[:args.max_report]})

    total = len(coverage["diagnostics"])
    summary = {
        "upstream": coverage["upstream"],
        "total_diagnostics": total,
        "covered": len(covered),
        "gaps": len(gaps),
        "runtime_free_text": len(runtime_free),
        "short_spine": len(short_spine),
        "coverage_percent": round(100.0 * len(covered) / max(total, 1), 2),
        "po_entries": len(entries),
        "translated_diagnostic_templates": len(translated_templates),
    }
    print(f"UPSTREAM_VERSION={coverage['upstream']['version']} commit={coverage['upstream']['commit']}")
    print(f"TOTAL={total} COVERED={len(covered)} GAPS={len(gaps)} "
          f"RUNTIME_FREE_TEXT={len(runtime_free)} SHORT_SPINE={len(short_spine)}")
    print(f"COVERAGE_PERCENT={summary['coverage_percent']}")
    print(f"PO_ENTRIES={len(entries)} TRANSLATED_TEMPLATES={len(translated_templates)}")
    for item in gaps[:10]:
        print(f"GAP={item['id']} variants={len(item['variants'])} sample={item['variants'][:2]}")
    if args.report:
        report = dict(summary)
        report["schema"] = 1
        report["generator"] = "tools/diagnostic_coverage.py"
        report["gap_details"] = gaps[:args.max_report]
        report["runtime_free_text_details"] = runtime_free
        report["short_spine_details"] = short_spine
        report["covered_diagnostics"] = covered
        REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"COVERAGE_REPORT=PASS file={REPORT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
