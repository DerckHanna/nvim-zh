#!/usr/bin/env python3
"""Validate pinned third-party source hashes and the exact adapter seams."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
ENVS = {
    'which-key': 'NVIM_ZH_TEST_WHICH_KEY',
    'telescope': 'NVIM_ZH_TEST_TELESCOPE',
    'nvim-tree': 'NVIM_ZH_TEST_NVIM_TREE',
    'lazy.nvim': 'NVIM_ZH_TEST_LAZY',
    'nvim-cmp': 'NVIM_ZH_TEST_NVIM_CMP',
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

dependencies = json.loads((ROOT / 'manifests/upstreams.json').read_text())['test_dependencies']
plenary = Path(os.environ['NVIM_ZH_TEST_PLENARY'])
for name, metadata in dependencies['plenary']['sources'].items():
    require(hashlib.sha256((plenary / name).read_bytes()).hexdigest() == metadata['sha256'],
            f'plenary:{name}: pinned dependency changed')

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

print(f'UPSTREAM_SOURCE_CONTRACT=PASS files={checked} plugins=5')
