#!/usr/bin/env python3
"""Validate pinned third-party source hashes and the exact adapter seams."""
import hashlib
import json
import os
from pathlib import Path

import catalog_tool

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
ENVS = {
    'which-key': 'NVIM_ZH_TEST_WHICH_KEY',
    'telescope': 'NVIM_ZH_TEST_TELESCOPE',
    'nvim-tree': 'NVIM_ZH_TEST_NVIM_TREE',
    'lazy.nvim': 'NVIM_ZH_TEST_LAZY',
    'nvim-cmp': 'NVIM_ZH_TEST_NVIM_CMP',
    'nvim-dap': 'NVIM_ZH_TEST_NVIM_DAP',
    'nvim-dap-ui': 'NVIM_ZH_TEST_NVIM_DAP_UI',
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


missing = [name for name in ENVS.values() if not os.environ.get(name)]
if missing:
    print('UPSTREAM_SOURCE_CONTRACT=FAIL missing=' + ','.join(missing))
    raise SystemExit(1)

manifest = json.loads((ROOT / 'manifests/upstreams.json').read_text(encoding='utf-8'))['upstreams']
checked = 0
for plugin, env in ENVS.items():
    root = Path(os.environ[env]).resolve()
    require(root.is_dir(), f'{plugin}: source root is not a directory: {root}')
    for name, metadata in manifest[plugin]['sources'].items():
        data = (root / name).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        require(actual == metadata['sha256'], f'{plugin}:{name}: {actual} != {metadata["sha256"]}')
        checked += 1

reference_counts = {}
for plugin in ('nvim-dap', 'nvim-dap-ui'):
    root = Path(os.environ[ENVS[plugin]]).resolve()
    entries, _ = catalog_tool.parse_po(ROOT / f'translations/po/zh_CN/{plugin}.po')
    reference_count = 0
    source_lines = {}
    for entry in entries:
        require(entry['references'], f'{plugin}: entry lacks a source reference: {entry["msgid"]!r}')
        for reference in entry['references']:
            name, separator, line_number = reference.rpartition(':')
            require(separator and line_number.isdigit(), f'{plugin}: invalid source reference: {reference}')
            require(name in manifest[plugin]['sources'], f'{plugin}: unpinned PO source: {name}')
            if name not in source_lines:
                source_lines[name] = (root / name).read_text(encoding='utf-8').splitlines()
            require(1 <= int(line_number) <= len(source_lines[name]),
                    f'{plugin}: source reference outside file: {reference}')
            reference_count += 1
    reference_counts[plugin] = (len(entries), reference_count)
print('DAP_PO_SOURCE_REFS=PASS ' + ' '.join(
    f'{plugin}_entries={counts[0]} {plugin}_refs={counts[1]}'
    for plugin, counts in reference_counts.items()))

dependencies = json.loads((ROOT / 'manifests/upstreams.json').read_text())['test_dependencies']
for dependency, metadata in dependencies.items():
    env = 'NVIM_ZH_TEST_' + dependency.upper().replace('-', '_').replace('.', '_')
    root = Path(os.environ[env])
    for name, source in metadata['sources'].items():
        require(hashlib.sha256((root / name).read_bytes()).hexdigest() == source['sha256'],
                f'{dependency}:{name}: pinned dependency changed')

which = Path(os.environ[ENVS['which-key']])
view = (which / 'lua/which-key/view.lua').read_text(encoding='utf-8')
util = (which / 'lua/which-key/util.lua').read_text(encoding='utf-8')
presets = (which / 'lua/which-key/plugins/presets.lua').read_text(encoding='utf-8')
require('desc = M.replace("desc", desc or "")' in view, 'which-key desc display seam changed')
require('title = opts.title or "which-key.nvim"' in util, 'which-key notification title changed')
require('desc = "Delete"' in presets and 'desc = "Spelling suggestions"' in presets,
        'which-key preset source literals changed')

telescope = Path(os.environ[ENVS['telescope']])
window = (telescope / 'lua/telescope/pickers/window.lua').read_text(encoding='utf-8')
actions = (telescope / 'lua/telescope/actions/init.lua').read_text(encoding='utf-8')
utils = (telescope / 'lua/telescope/utils.lua').read_text(encoding='utf-8')
require('function p_window.get_initial_window_options(picker)' in window,
        'Telescope initial title projection changed')
for field in ('preview_title', 'results_title', 'prompt_title'):
    require(f'title = picker.{field}' in window, f'Telescope projection lost {field}')
for title in ('Live Grep', 'LSP Dynamic Workspace Symbols'):
    require(title in actions, f'Telescope behavior title missing: {title}')
require('title = "telescope.nvim"' in utils, 'Telescope notification title changed')

tree = Path(os.environ[ENVS['nvim-tree']])
keymap = (tree / 'lua/nvim-tree/keymap.lua').read_text(encoding='utf-8')
notify = (tree / 'lua/nvim-tree/notify.lua').read_text(encoding='utf-8')
require('function M.on_attach_default(bufnr)' in keymap, 'nvim-tree default attach seam changed')
require('desc = "nvim-tree: " .. desc' in keymap, 'nvim-tree mapping prefix changed')
require('vim.notify(msg, level, { title = "NvimTree" })' in notify,
        'nvim-tree notification title changed')

dap_root = Path(os.environ[ENVS['nvim-dap']])
dap_ui = (dap_root / 'lua/dap/ui.lua').read_text(encoding='utf-8')
dap_repl = (dap_root / 'lua/dap/repl.lua').read_text(encoding='utf-8')
dap_utils = (dap_root / 'lua/dap/utils.lua').read_text(encoding='utf-8')
dap_breakpoints = (dap_root / 'lua/dap/breakpoints.lua').read_text(encoding='utf-8')
dap_entity = (dap_root / 'lua/dap/entity.lua').read_text(encoding='utf-8')
dap_health = (dap_root / 'lua/dap/health.lua').read_text(encoding='utf-8')
dap_init = (dap_root / 'lua/dap.lua').read_text(encoding='utf-8')
dap_session = (dap_root / 'lua/dap/session.lua').read_text(encoding='utf-8')
require("vim.notify(msg, log_level, {title = 'DAP'})" in dap_utils,
        'nvim-dap notification title changed')
require('function M.pick_one_sync(items, prompt, label_fn)' in dap_ui
        and 'function M.pick_one(items, prompt, label_fn, cb)' in dap_ui,
        'nvim-dap structured selector seam changed')
require('vim.fn.prompt_setcallback(buf, execute)' in dap_repl
        and "M.append('Commands:')" in dap_repl and "M.append('Custom commands:')" in dap_repl,
        'nvim-dap REPL new-buffer/help seams changed')
require('function M.to_qf_list(breakpoints)' in dap_breakpoints
        and '"Log message: " .. bp.logMessage' in dap_breakpoints,
        'nvim-dap quickfix raw-field projection changed')
require("vim.fn.input(string.format('New `%s` value: ', item.name))" in dap_entity
        and "vim.fn.input(string.format('New `%s` expression: ', item.name))" in dap_entity,
        'nvim-dap variable/expression direct input seams changed')
require('function M.set_exception_breakpoints(filters, exceptionOptions)' in dap_init
        and 'function Session:set_exception_breakpoints(filters, exceptionOptions, on_done)' in dap_session
        and 'vim.fn.input("Exception breakpoint filters: "' in dap_session,
        'nvim-dap exception-filter direct input seam changed')
require('function M.check()' in dap_health, 'nvim-dap health display seam changed')

dapui = Path(os.environ[ENVS['nvim-dap-ui']])
canvas = (dapui / 'lua/dapui/render/canvas.lua').read_text(encoding='utf-8')
render = (dapui / 'lua/dapui/render/init.lua').read_text(encoding='utf-8')
util_ui = (dapui / 'lua/dapui/util.lua').read_text(encoding='utf-8')
windows = (dapui / 'lua/dapui/windows/init.lua').read_text(encoding='utf-8')
init_ui = (dapui / 'lua/dapui/init.lua').read_text(encoding='utf-8')
require('function Canvas:write(text, opts)' in canvas, 'nvim-dap-ui Canvas.write display seam changed')
require('self.matches[#self.matches + 1] = { opts.group' in canvas,
        'nvim-dap-ui Canvas highlight projection changed')
require('M.new_canvas = canvas.new' in render, 'nvim-dap-ui render canvas alias changed')
require('title = "nvim-dap-ui"' in util_ui, 'nvim-dap-ui notification title changed')
require('function M.apply_mapping(mappings, func, buffer, label)' in util_ui
        and 'desc = label' in util_ui, 'nvim-dap-ui mapping description sink changed')
require('print("Select window: ")' in util_ui, 'nvim-dap-ui default Window prompt changed')
require('function M.open_float(name, element, position, settings)' in windows
        and 'title = settings.title' in windows, 'nvim-dap-ui float title projection changed')
require('prompt = "Select an element:"' in init_ui and '{ title = elem_name }' in init_ui,
        'nvim-dap-ui selector/default title literals changed')

print(f'UPSTREAM_SOURCE_CONTRACT=PASS files={checked} plugins={len(ENVS)}')
