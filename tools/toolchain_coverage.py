#!/usr/bin/env python3
"""Exercise every inventoried shape with the production Lua matchers and join real observations."""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
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


def render(template):
    return re.sub(r"%%|%(\d+)", lambda match: f"样例_{match[1]}" if match[1] else "%", template)


def samples(domain, source):
    if domain == "clang-tidy":
        for row in source["checks"]:
            for message in row["messages"]:
                for shape in inventory.normalize_template(message["message"], {}):
                    for variant in inventory.expand_plural_suffixes(inventory.strip_simple_modifiers(shape)):
                        yield {"domain": domain, "id": row["name"], "code": row["name"],
                               "source": row["source"], "line": message["line"], "variant": variant,
                               "message": render(variant), "level": "note" if message["note"] else "warning",
                               "interface": "quickfix", "evidence": "synthetic"}
        return
    for row in source["diagnostics"]:
        name = row["id"]
        for variant in row["variants"]:
            body = render(variant)
            for code in [f"-W{group}" for group in row["groups"]] or [None]:
                interface = "driver" if row["component"] == "Driver" else "quickfix"
                yield {"domain": domain, "id": name, "source": row["source"], "line": row["line"],
                       "variant": variant, "level": row["severity"],
                       "code": code or (name.removeprefix("err_") if domain == "clangd" else None),
                       "interface": "textDocument/publishDiagnostics" if domain == "clangd" else interface,
                       "message": body[:1].upper() + body[1:] if domain == "clangd" else body,
                       "evidence": "synthetic",
                       "expected_raw": name in FREE_TEXT or bool(RAW.fullmatch(variant))}


def observed(compiler, clangd):
    for run in [*compiler["compiler"], *compiler["clang_tidy"],
                *(compiler["fix"][key] for key in ("export", "apply", "recheck"))]:
        domain = "clang-tidy" if run["tool"] == "clang-tidy" else "clang"
        for row in run["diagnostics"]:
            special = None
            if row["kind"] != "diagnostic":
                special = "original_edit" if row["kind"] == "fix_edit" else "include_stack"
            elif row["origin"] not in DOMAINS and row["origin"] != "clang++":
                special = "subtool_output"
            elif row.get("code") in PROTECTED or run["case"] == "collision.c" or (
                    run["case"] == "preprocessor.c" and "用户自定义" in row["message"]):
                special = "project_text"
            yield {"evidence": "cli", "case": run["case"], "argv": run["argv"], "exit": run["exit"],
                   "interface": "driver" if "file" not in row else run["interface"],
                   "domain": domain, "code": row.get("code") or row.get("associated_check"),
                   "expected_raw": special, **{key: value for key, value in row.items() if key != "code"}}
    for push in clangd["push"]:
        for row in push["params"]["diagnostics"]:
            yield {"evidence": "push", "domain": "clangd", "interface": push["method"],
                   "case": push["params"]["uri"], "expected_raw": row.get("code") == "pp_hash_error",
                   "protocol": row, "lsp_source": row.get("source"), **{
                       key: row[key] for key in ("message", "code") if key in row}}


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
local cli = require('nvim-zh.compiler').match_message
local lsp = require('nvim-zh.diagnostics').match_message
local out = {}
for i, row in ipairs(read('samples.json')) do
  local body, reason, context, key
  if row.expected_raw then
    reason = type(row.expected_raw) == 'string' and row.expected_raw or 'argument_only'
    body = row.message
  elseif row.domain == 'clangd' then
    body, context, key = lsp(row.message, row.code, row.lsp_source or 'clang')
    reason = body and body ~= row.message and 'translated' or 'no_match'
  else
    body, reason, context, key = cli(row.domain, row.message, row.code, row.level, row.interface)
  end
  out[i] = { text = body, reason = reason, context = context, entry_id = key }
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
        subprocess.run([nvim, "--headless", "-u", "NONE", "-l", str(path / "match.lua")],
                       env=env, timeout=90, check=True)
        return read(path / "results.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--clangd", required=True, type=Path)
    parser.add_argument("--tui", type=Path, help="the Chinese TUI wire.json, if collected")
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
    rows = [row for domain in DOMAINS for row in samples(domain, source[domain])]
    rows.extend(observed(real_compiler, real_clangd))
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
        for scope in ("synthetic", "cli", "push"):
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
    tui = read(args.tui) if args.tui else None
    methods = Counter(row["method"] for row in tui["wire"]) if tui else {}
    for row in protocol["methods"]:
        row["recorded_events"] = methods.get(row["method"], 0)
        if tui and row["method"] in tui["raw"] and "err" in tui["raw"][row["method"]]:
            row["rpc_error"] = tui["raw"][row["method"]]["err"]["code"]
    values = {"summary": summary, "catalog_contexts": methodology, "samples": rows,
              "tidy_check_registry": {"enabled": sorted(enabled), "enabled_without_registration": sorted(enabled - tidy_registered),
                                      "source_only": sorted(tidy_registered - enabled)},
              "protocol": protocol, "tui_display": tui["displayed"] if tui else None}
    write(args.report, values)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"TOOLCHAIN_COVERAGE=RECORDED tidy_enabled={len(enabled)} registration_gaps={len(enabled - tidy_registered)}")
    raw_reasons = {"argument_only", "project_text", "original_edit", "subtool_output"}
    gaps = sum(row["match"]["reason"] not in raw_reasons | {"translated"} for row in rows)
    if args.require_complete and (gaps or enabled - tidy_registered or source["clang-tidy"]["scan_errors"]):
        print(f"TOOLCHAIN_COMPLETE=FAIL unmatched_inputs={gaps}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
