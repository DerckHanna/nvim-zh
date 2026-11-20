#!/usr/bin/env python3
"""Run sampled LLVM diagnostics and optional recorded LSP messages through the Lua matcher."""
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
import resource_bundle

ROOT = Path(__file__).resolve().parent.parent
INVENTORY = ROOT / 'manifests/clangd-coverage.json'

# Clang substitutes user-provided text as the whole diagnostic in these cases.
FREE_TEXT = {'err_apinotes_message', 'note_apinotes_message', 'warn_apinotes_message',
             'err_diagnose_if_succeeded', 'warn_diagnose_if_succeeded', 'err_inline_ms_asm_parsing',
             'err_pp_hash_error', 'pp_hash_warning', 'err_pragma_message', 'warn_pragma_message'}


def render(variant: str) -> str:
    text = re.sub(r'%%|%(\d+)', lambda m: f'nvimzh_arg_{m[1]}' if m[1] else '%', variant)
    return text[:1].upper() + text[1:]


def codes(row: dict) -> tuple[str, ...]:
    # clangd prefers -W<group> and otherwise removes only the err_ prefix.
    return tuple(f'-W{group}' for group in row['groups']) or (row['id'].removeprefix('err_'),)


def run_matcher(samples: list[dict], catalog: dict, binary: str) -> list[str]:
    lua = """
local root, dir = vim.env.NVIM_ZH_ROOT, vim.env.NVIM_ZH_COVERAGE_TMP
vim.opt.runtimepath:prepend(root)
local function data(name)
  return vim.json.decode(table.concat(vim.fn.readfile(dir .. '/' .. name), '\\n'))
end
require('nvim-zh.catalog').register_owned('clangd', function() return data('catalog.json') end, { locale = 'zh_CN' })
local match = require('nvim-zh.diagnostics').match_message
local output = {}
for i, sample in ipairs(data('samples.json')) do
  local text, context = match(sample.message, sample.code, sample.source)
  output[i] = text and text ~= sample.message and context or false
end
vim.fn.writefile({vim.json.encode(output)}, dir .. '/results.json')
"""
    with tempfile.TemporaryDirectory(prefix='nvim-zh-coverage-') as directory:
        path = Path(directory)
        (path / 'match.lua').write_text(lua, encoding='utf-8')
        (path / 'samples.json').write_bytes(resource_bundle.encoded(samples))
        (path / 'catalog.json').write_bytes(resource_bundle.encoded(catalog))
        env = dict(os.environ, NVIM_ZH_ROOT=str(ROOT), NVIM_ZH_COVERAGE_TMP=directory,
                   XDG_RUNTIME_DIR=directory, NVIM_LOG_FILE=str(path / 'nvim.log'))
        subprocess.run([binary, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', str(path / 'match.lua')],
                       env=env, timeout=60, check=True)
        return json.loads((path / 'results.json').read_text(encoding='utf-8'))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, default=INVENTORY)
    parser.add_argument('--report', type=Path, help='write report with sampled matches and observations')
    parser.add_argument('--observations', type=Path, help='a real_smoke.py observation JSON')
    parser.add_argument('--nvim', default=os.environ.get('NVIM_BIN', 'nvim'))
    args = parser.parse_args(argv)
    inventory = json.loads(args.inventory.read_text(encoding='utf-8'))
    domain = catalog_tool.builtin_sources(ROOT, optional=True)['clangd']
    catalog = resource_bundle.catalog(domain)
    samples, owners = [], []
    dynamic = []
    for record in inventory['diagnostics']:
        for variant in record['variants']:
            if record['id'] in FREE_TEXT or re.fullmatch(r'%\d+', variant):
                dynamic.append((record['id'], variant))
                continue
            for code in codes(record):
                samples.append({'message': render(variant), 'code': code, 'source': 'clang'})
                owners.append((record['id'], variant))
    observation_start = len(samples)
    observation = None
    if args.observations:
        observation = json.loads(args.observations.read_text(encoding='utf-8'))
        for message in observation['push']:
            for row in message['params']['diagnostics']:
                samples.append({key: row[key] for key in ('message', 'code', 'source') if key in row})
    results = run_matcher(samples, catalog, args.nvim)
    covered = {}
    for owner, context in zip(owners, results):
        if context:
            covered.setdefault(owner, set()).add(context)
    ids = {code for row in inventory['diagnostics'] for code in codes(row)}
    contexts = Counter(row['context'] for row in catalog['entries'])
    summary = {
        'source_inventory': inventory['upstream'],
        'source_diagnostics': inventory['counts']['diagnostics'],
        'source_variants': inventory['counts']['variants'],
        'records_with_capped_variants': inventory['counts']['diagnostics_with_capped_variants'],
        'generic_entries': contexts['diagnostic'],
        'source_code_entries': sum(contexts[key] for key in ids),
        'other_contexts': dict(sorted((key, count) for key, count in contexts.items()
                                      if key != 'diagnostic' and key not in ids)),
        'sampled_diagnostics_with_matches': len({owner[0] for owner in covered}),
        'sampled_variants_with_matches': len(covered),
        'sampled_generic_matches': sum('diagnostic' in contexts for contexts in covered.values()),
        'sampled_scoped_matches': sum(bool(contexts - {'diagnostic'}) for contexts in covered.values()),
        'expected_raw_variants': len(dynamic),
    }
    if observation is not None:
        runtime = results[observation_start:]
        summary['real_observations'] = {
            'binary': observation['clangd'],
            'server_info': observation['initialize_result']['result'].get('serverInfo'),
            'push_total': len(runtime),
            'push_body_matches': sum(bool(result) for result in runtime),
            'pull_status': observation['pull_status'],
        }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if args.report:
        args.report.write_text(json.dumps({
            'summary': summary,
            'sampled_matches': [{'id': id, 'variant': variant, 'contexts': sorted(scopes)}
                                for (id, variant), scopes in sorted(covered.items())],
            'expected_raw': [{'id': id, 'variant': variant} for id, variant in dynamic],
            'real_messages': [{'source': sample.get('source'), 'code': sample.get('code'), 'context': result}
                              for sample, result in zip(samples[observation_start:], results[observation_start:])],
        }, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
