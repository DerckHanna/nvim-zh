#!/usr/bin/env python3
"""Exercise every inventoried shape with the production Lua matchers and join real observations."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import catalog_tool
import diagnostic_inventory as inventory
import resource_bundle
from toolchain_inventory import FREE_TEXT

ROOT = Path(__file__).resolve().parents[1]
DOMAINS = ("clang", "clangd", "clang-tidy")
RAW = re.compile(r"%\d+")
PROTECTED = {"-W#warnings", "-W#pragma-messages", "-Wuser-defined-warnings", "-Wapinotes"}


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    path.write_text(json.dumps(value, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def render(template, diagnostic=None):
    # These call sites pass QualType, declarations, and an ordinal index to
    # FormatDiagnostic. Exercise their printed forms instead of bare strings.
    args = {}
    if diagnostic == "note_ovl_candidate_bad_conv":
        args = {"3": "'类型甲' (aka 'long long')", "4": "'类型乙'", "6": "1st"}
    elif diagnostic == "err_template_arg_list_different_arity":
        args = {"2": "'示例模板'"}
    elif diagnostic in {"err_param_redefinition", "err_redefinition_different_kind"}:
        args = {"0": "'示例名称'"}
    elif diagnostic in {"err_undeclared_var_use_suggest", "err_unknown_typename_suggest",
                        "err_unknown_type_or_class_name_suggest"}:
        args = {"0": "'示例名称'", "1": "'可用名称'", "2": "'可用名称'"}
    elif diagnostic == "err_typecheck_call_too_many_args_one":
        args = {"1": "'示例形参'", "2": "2"}
    return re.sub(r"%%|%(\d+)|\{(location)\}", lambda match: "示例.h:1" if match[2] else
                  args.get(match[1], f"样例_{match[1]}") if match[1] else "%", template)


def samples(domain, source):
    for row in source.get("frontend_messages", []):
        for variant in row["variants"]:
            yield {"domain": domain, "id": row["id"], "source": row["source"], "line": row["line"],
                   "variant": variant, "interface": row["interface"], "message": render(variant),
                   "evidence": "synthetic"}
    if domain == "clang-tidy":
        for row in [*source["checks"], *source["analyzer_checkers"]]:
            for message in row["messages"]:
                for shape in inventory.normalize_template(message["message"], {}):
                    for variant in inventory.expand_plural_suffixes(inventory.strip_simple_modifiers(shape)):
                        yield {"domain": domain, "id": row["name"], "code": row["name"],
                               "source": message.get("source", row["source"]), "line": message["line"], "variant": variant,
                               "message": render(variant), "level": "note" if message["note"] else "warning",
                               "interface": "quickfix", "evidence": "synthetic"}
        return
    for row in source["diagnostics"]:
        name = row["id"]
        for variant in row["variants"]:
            body = render(variant, name)
            for code in [f"-W{group}" for group in row["groups"]] or [None]:
                interface = "driver" if row["component"] == "Driver" else "quickfix"
                yield {"domain": domain, "id": name, "source": row["source"], "line": row["line"],
                       "variant": variant, "level": row["severity"],
                       "code": code or (name.removeprefix("err_") if domain == "clangd" else None),
                       "interface": "textDocument/publishDiagnostics" if domain == "clangd" else interface,
                       "message": body[:1].upper() + body[1:] if domain == "clangd" else body,
                       "evidence": "synthetic",
                       "expected_raw": name in FREE_TEXT or variant == "" or bool(RAW.fullmatch(variant))}


def observed(compiler, clangd):
    for run in [*compiler["compiler"], *compiler["clang_tidy"],
                *(compiler["fix"][key] for key in ("export", "apply", "recheck"))]:
        domain = "clang-tidy" if run["tool"] == "clang-tidy" else "clang"
        for row in run["diagnostics"]:
            special = None
            if row["kind"] != "diagnostic":
                special = "original_edit" if row["kind"] == "fix_edit" else None
            elif row["origin"] not in DOMAINS and row["origin"] != "clang++":
                special = "subtool_output"
            elif row.get("code") in PROTECTED or run["case"] == "collision.c" or (
                    run["case"] == "preprocessor.c" and "用户自定义" in row["message"]):
                special = "project_text"
            yield {"evidence": "cli", "case": run["case"], "argv": run["argv"], "exit": run["exit"],
                   "interface": "include_stack" if row["kind"] == "include_stack" else
                   "driver" if "file" not in row else run["interface"],
                   "domain": domain, "code": row.get("code") or row.get("associated_check"),
                   "expected_raw": special, **{key: value for key, value in row.items() if key != "code"}}
    yield from push_samples(clangd["push"], "push")


def push_samples(pushes, evidence):
    for push in pushes:
        for row in push["params"]["diagnostics"]:
            domain = "clang-tidy" if row.get("source") == "clang-tidy" else "clangd"
            common = {"domain": domain, "interface": push["method"], "case": push["params"]["uri"],
                      "evidence": evidence, "code": row.get("code"), "lsp_source": row.get("source")}
            yield {**common, "message": row["message"], "protocol": row}
            for note in row.get("relatedInformation", []):
                yield {**common, "level": "note", "message": note["message"], "protocol": note}


LUA = """
vim.opt.rtp:prepend(vim.env.NVIM_ZH_ROOT)
local dir = vim.env.NVIM_ZH_COVERAGE
local function read(name)
  return vim.json.decode(table.concat(vim.fn.readfile(dir .. '/' .. name), '\\n'), {luanil={object=true}})
end
local catalog = require('nvim-zh.catalog')
for _, domain in ipairs({ 'clang', 'clangd', 'clang-tidy' }) do
  catalog.register_owned(domain, function() return read(domain .. '.json') end, { locale = 'zh_CN' })
end
local cli = require('nvim-zh.tool_message').match_message
local lsp = require('nvim-zh.diagnostics')
local out = {}
for i, row in ipairs(read('samples.json')) do
  local body, reason, context, key, nested_key
  if row.lsp_source == 'clang-tidy' then
    body, reason, context, key = lsp.match_forwarded(row.message, row.code, row.level == 'note')
  elseif row.expected_raw then
    reason = type(row.expected_raw) == 'string' and row.expected_raw or 'argument_only'
    body = row.message
  elseif row.domain == 'clangd' then
    body, context, key, reason, nested_key =
      lsp.match_message(row.message, row.code, row.lsp_source or 'clang', row.level == 'note')
    reason = reason or 'no_match'
    body = body or row.message
  else
    body, reason, context, key, nested_key = cli(row.domain, row.message, row.code, row.level, row.interface)
  end
  out[i] = { text = body, reason = reason, context = context, entry_id = key, nested_entry_id = nested_key }
end
vim.fn.writefile({vim.json.encode(out)}, dir .. '/results.json')
"""


def match_all(rows, catalogs, nvim):
    with tempfile.TemporaryDirectory(prefix="nvim-zh-toolchain-coverage-") as tmp:
        path = Path(tmp)
        for domain, catalog in catalogs.items():
            write(path / f"{domain}.json", catalog)
        write(path / "samples.json", rows)
        (path / "match.lua").write_text(LUA, encoding="utf-8")
        env = dict(os.environ, NVIM_ZH_ROOT=str(ROOT), NVIM_ZH_COVERAGE=tmp,
                   XDG_STATE_HOME=tmp, XDG_DATA_HOME=tmp, XDG_RUNTIME_DIR=tmp)
        subprocess.run([nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", str(path / "match.lua")],
                       env=env, timeout=90, check=True)
        return read(path / "results.json")


def verify_evidence(nvim, compiler, clangd, tui, comparison, baseline, protocol):
    issues = []
    with Path(shutil.which(nvim) or nvim).open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != baseline["baseline"]["sha256"]:
            issues.append("neovim_binary_unverified")
    cli_binaries = {Path(path).name: value["sha256"] for path, value in compiler["binaries"].items()}
    for name in ("clang", "clang++", "clang-tidy"):
        if cli_binaries.get(name) != baseline["binaries"][name]["sha256"]:
            issues.append(f"cli_binary_unverified:{name}")
    if clangd["clangd"].get("sha256") != baseline["binaries"]["clangd"]["sha256"]:
        issues.append("clangd_binary_unverified")
    if not clangd["push"] or not clangd["pull"]:
        issues.append("clangd_smoke_missing")
    if not tui or tui.get("language") != "on" or not comparison:
        issues.append("tui_differential_missing")
    elif not {"raw", "builds", "files", "capabilities", "attachments"}.issubset(comparison.get("same", [])):
        issues.append("tui_differential_incomplete")
    elif not {"textDocument/codeAction", "workspace/applyEdit", "textDocument/hover",
              "textDocument/completion", "textDocument/signatureHelp"}.issubset(comparison.get("same_wire_methods", [])):
        issues.append("tui_protocol_differential_incomplete")
    for row in protocol["methods"]:
        method = row["method"]
        exists = row["recorded_events"] > 0
        if row.get("evidence") == "source_absent":
            if exists:
                issues.append(f"unexpected_protocol_method:{method}")
        elif not exists and row.get("evidence") != "asynchronous":
            issues.append(f"protocol_evidence_missing:{method}")
        if "rpc_error" in row and row.get("observed_rpc_error") != row["rpc_error"]:
            issues.append(f"protocol_error_unverified:{method}")
        if row.get("success_marker") and not row.get("independent_contract_passed"):
            issues.append(f"protocol_success_contract_unverified:{method}")
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--clangd", required=True, type=Path)
    parser.add_argument("--tui", type=Path, help="the Chinese TUI wire.json, if collected")
    parser.add_argument("--comparison", type=Path, help="the TUI comparison.json next to the two sessions")
    parser.add_argument("--contracts", type=Path, help="log containing the independent LSP contract results")
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--nvim", default=os.environ.get("NVIM_BIN", "nvim"))
    parser.add_argument("--require-complete", action="store_true", help="fail after writing a report with gaps")
    args = parser.parse_args()
    if args.report.resolve().is_relative_to(ROOT):
        parser.error("--report must be outside the checkout")
    source = {domain: read(ROOT / "manifests" / f"{domain}-coverage.json") for domain in DOMAINS}
    catalogs = {domain: resource_bundle.catalog(catalog_tool.builtin_sources(ROOT, optional=True)[domain])
                for domain in DOMAINS}
    real_compiler, real_clangd = read(args.compiler), read(args.clangd)
    tui = read(args.tui) if args.tui else None
    comparison_path = args.comparison or (args.tui.parent.parent / "comparison.json" if args.tui else None)
    comparison = read(comparison_path) if comparison_path and comparison_path.is_file() else None
    rows = [row for domain in DOMAINS for row in samples(domain, source[domain])]
    rows.extend(observed(real_compiler, real_clangd))
    if tui:
        rows.extend(push_samples((row for row in tui["wire"] if row["method"] == "textDocument/publishDiagnostics"),
                                 "tui_push"))
    matches = match_all(rows, catalogs, args.nvim)
    if len(rows) != len(matches):
        raise RuntimeError("Lua did not return a result for every input")
    for row, match in zip(rows, matches):
        row["match"] = match
    methodology = {domain: {context: count for context, count in sorted(
        Counter(row["context"] for row in catalog["entries"]).items())}
        for domain, catalog in catalogs.items()}
    summary = {}
    for domain in DOMAINS:
        subset = [row for row in rows if row["domain"] == domain]
        items = {}
        for scope in ("synthetic", "cli", "push", "tui_push"):
            selected = [row for row in subset if row["evidence"] == scope]
            if selected:
                items[scope] = dict(Counter(row["match"]["reason"] for row in selected))
                if scope == "synthetic":
                    items["matched_source_ids"] = len({row["id"] for row in selected
                                                       if row["match"]["reason"] == "translated"})
                    items["matched_contexts"] = dict(Counter(row["match"].get("context", "")
                                                            for row in selected
                                                            if row["match"]["reason"] == "translated"))
        summary[domain] = {"source": source[domain]["counts"], **items}
    tidy_registered = {row["name"] for row in [*source["clang-tidy"]["checks"], *source["clang-tidy"]["analyzer_checkers"]]}
    enabled = set(real_compiler["enabled_checks"])
    protocol = read(ROOT / "manifests/clangd-protocol.json")
    methods = Counter(row["method"] for row in tui["wire"]) if tui else {}
    contract_log = args.contracts.read_text(encoding="utf-8") if args.contracts else ""
    for row in protocol["methods"]:
        row["recorded_events"] = methods.get(row["method"], 0)
        if tui and row["method"] in tui["raw"] and "err" in tui["raw"][row["method"]]:
            row["observed_rpc_error"] = tui["raw"][row["method"]]["err"]["code"]
        if row.get("success_marker"):
            row["independent_contract_passed"] = bool(re.search(
                rf"^{re.escape(row['success_marker'])}\b", contract_log, re.M))
    baseline = read(ROOT / "manifests/toolchain.json")
    issues = verify_evidence(args.nvim, real_compiler, real_clangd, tui, comparison, baseline, protocol)
    tidy = source["clang-tidy"]
    analyzer_gaps = {row["name"]: row["message_audit"] for row in tidy["analyzer_checkers"]
                     if row["name"] in enabled and row["message_audit"] != "complete"}
    if analyzer_gaps:
        issues.append("enabled_analyzer_inventories_incomplete")
    if tidy["counts"]["unresolved_calls"]:
        issues.append("tidy_calls_unresolved")
    values = {"summary": summary, "catalog_contexts": methodology, "samples": rows,
              "tidy_check_registry": {"enabled": sorted(enabled), "enabled_without_registration": sorted(enabled - tidy_registered),
                                      "source_only": sorted(tidy_registered - enabled)},
              "protocol": protocol, "tui_display": tui["displayed"] if tui else None,
              "tui_comparison": comparison, "evidence_gaps": issues,
              "enabled_analyzer_audit_gaps": analyzer_gaps}
    write(args.report, values)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"TOOLCHAIN_COVERAGE=RECORDED tidy_enabled={len(enabled)} registration_gaps={len(enabled - tidy_registered)}")
    raw_reasons = {"argument_only", "project_text", "original_edit", "subtool_output"}
    gaps = sum(row["match"]["reason"] not in raw_reasons | {"translated"} for row in rows)
    if args.require_complete and (gaps or issues or enabled - tidy_registered or tidy["scan_errors"]):
        print(f"TOOLCHAIN_COMPLETE=FAIL unmatched_inputs={gaps} evidence_gaps={len(issues)} "
              f"analyzer_audit_gaps={len(analyzer_gaps)}")
        for issue in issues:
            print(f"TOOLCHAIN_EVIDENCE_GAP={issue}")
        return 1
    if args.require_complete:
        print("TOOLCHAIN_COMPLETE=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
