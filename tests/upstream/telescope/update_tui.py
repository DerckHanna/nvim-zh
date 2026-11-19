"""Use real vim.pack operations and a local two-revision Telescope source."""
import os
import shutil
import sys
import tempfile
from pathlib import Path

from adapter_tui import Terminal, commit, git, init_for, lua_literal


def picker(ui, title):
    ui.command('Telescope find_files')
    ui.expect(title, 'tui-fixture.txt')
    ui.send(b'\x1b\x1b')
    ui.expect('ADAPTER_UPDATE_WORKSPACE')


assert sys.argv[1] == 'update'
with tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-update-') as directory:
    root = Path(directory)
    source = root / 'upstream'
    shutil.copytree(os.environ['NVIM_ZH_TEST_TELESCOPE'], source, ignore=shutil.ignore_patterns('.git'))
    git(source, 'init', '-b', 'main')
    original = commit(source, 'Original Telescope fixture')
    path = source / 'lua/telescope/pickers/window.lua'
    content = path.read_bytes()
    path.write_bytes(content + b'\n-- Alternate upstream source used by the update test.\n')
    changed = commit(source, 'Upstream update')
    path.write_bytes(content)
    restored = commit(source, 'Restore original upstream content')
    remote = root / 'remote.git'
    git(root, 'clone', '--bare', str(source), str(remote))
    git(remote, 'update-ref', 'refs/heads/main', original)
    additional = f"""
vim.api.nvim_buf_set_lines(0, 0, -1, false, {{ 'ADAPTER_UPDATE_WORKSPACE' }})
vim.env.GIT_CONFIG_COUNT = '1'
vim.env.GIT_CONFIG_KEY_0 = 'url.' .. {lua_literal(remote.as_uri())} .. '.insteadOf'
vim.env.GIT_CONFIG_VALUE_0 = 'https://github.com/nvim-telescope/telescope.nvim'
vim.pack.add({{{{src=vim.env.GIT_CONFIG_VALUE_0, name='telescope-fixture'}}}}, {{ confirm = false, load = true }})
require('telescope').setup()
"""
    init = init_for('telescope', True, additional, ('NVIM_ZH_TEST_PLENARY',))
    first, second = root / 'first', root / 'second'
    first.mkdir()
    second.mkdir()
    files = {'tui-fixture.txt': 'fixture update\n'}
    with Terminal(first, init, files=files) as ui:
        ui.expect('ADAPTER_UPDATE_WORKSPACE')
        picker(ui, '查找文件')
        git(remote, 'update-ref', 'refs/heads/main', changed)
        ui.command('lua vim.pack.update({"telescope-fixture"})')
        ui.expect('Upstream update')
        ui.command('quit')
        ui.expect('ADAPTER_UPDATE_WORKSPACE')
        picker(ui, '查找文件')
        ui.command('lua vim.pack.update({"telescope-fixture"})')
        ui.expect('Upstream update')
        ui.command('write')
        ui.expect('ADAPTER_UPDATE_WORKSPACE')
        picker(ui, 'Find Files')
        ui.command('lua print(require("nvim-zh").status().adapters.telescope.surfaces.initial_titles.status)')
        ui.expect('stale_generation')
        git(remote, 'update-ref', 'refs/heads/main', restored)
        ui.command('lua vim.pack.update({"telescope-fixture"}, {force=true})')
        ui.command('lua vim.api.nvim_buf_set_lines(0, 1, 1, false, '
                   '{vim.pack.get({"telescope-fixture"}, {info=false})[1].rev})')
        ui.expect(restored)
        picker(ui, 'Find Files')
    with Terminal(second, init, files=files) as ui:
        ui.expect('ADAPTER_UPDATE_WORKSPACE')
        picker(ui, '查找文件')
print('TUI=PASS adapter=telescope case=update rows=32 cols=110 confirm cancel fallback new-generation recovery')
