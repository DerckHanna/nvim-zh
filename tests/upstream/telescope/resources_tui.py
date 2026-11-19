"""Exercise an adapter catalog update and implementation restart through the TUI."""
from pathlib import Path
import shutil
import sys
import tempfile

from adapter_tui import ROOT, Terminal, commit, git, init_for, lua_literal
import resource_bundle


def publish(tree):
    resource_bundle.write(tree / 'resources', resource_bundle.contents(tree))


def picker(ui, title):
    ui.command('Telescope find_files')
    ui.expect(title, 'resource-fixture.txt')
    ui.send(b'\x1b\x1b')
    ui.expect('ADAPTER_RESOURCE_WORKSPACE', reject=(title,))


def update(ui, message, *, accept=True):
    ui.command('lua vim.pack.update({"zh-fixture"})')
    ui.expect(message)
    ui.command('write' if accept else 'quit')
    ui.expect('ADAPTER_RESOURCE_WORKSPACE')


def await_release(ui, predicate, marker):
    ui.command(f'lua assert(vim.wait(5000, function() return {predicate} end, 25)); '
               f'vim.api.nvim_buf_set_lines(0, 1, -1, false, {{{lua_literal(marker)}}})')
    ui.expect(marker)


assert sys.argv[1] == 'resources_update'
with tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-resources-tui-') as directory:
    temp = Path(directory)
    releases = temp / 'releases'
    releases.mkdir()
    for name in ('build', 'doc', 'lua', 'manifests', 'plugin', 'resources', 'translations'):
        shutil.copytree(ROOT / name, releases / name)
    shutil.copy2(ROOT / 'VERSION', releases / 'VERSION')
    git(releases, 'init', '-b', 'main')
    initial = commit(releases, 'Initial adapter release')
    po = releases / 'translations/po/zh_CN/telescope.po'
    text = po.read_text()
    assert 'msgstr "查找文件"' in text
    po.write_text(text.replace('msgstr "查找文件"', 'msgstr "文件检索"', 1))
    publish(releases)
    translated = commit(releases, 'Adapter translation update')
    target = releases / 'lua/nvim-zh/adapters/telescope.lua'
    target.write_text(target.read_text() + '\n-- Different adapter implementation for the TUI update fixture.\n')
    po.write_text(text.replace('msgstr "查找文件"', 'msgstr "搜索文件"', 1))
    publish(releases)
    implementation = commit(releases, 'Adapter implementation update')
    remote = temp / 'remote.git'
    git(temp, 'clone', '--bare', str(releases), str(remote))
    git(remote, 'update-ref', 'refs/heads/main', initial)
    bootstrap = f"""
vim.pack.add({{{{src={lua_literal(remote.as_uri())}, name='zh-fixture'}}}}, {{ confirm = false, load = false }})
vim.env.NVIM_ZH_ROOT = vim.pack.get({{'zh-fixture'}}, {{info=false}})[1].path
"""
    init = bootstrap + init_for('telescope', True, """
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'ADAPTER_RESOURCE_WORKSPACE' })
vim.cmd('runtime plugin/telescope.lua')
require('telescope').setup()
""", ('NVIM_ZH_TEST_PLENARY', 'NVIM_ZH_TEST_TELESCOPE'), verify=True)
    first, second = temp / 'first', temp / 'second'
    first.mkdir()
    second.mkdir()
    files = {'resource-fixture.txt': 'resource update fixture\n'}
    with Terminal(first, init, files=files) as ui:
        ui.expect('ADAPTER_RESOURCE_WORKSPACE')
        picker(ui, '查找文件')
        git(remote, 'update-ref', 'refs/heads/main', translated)
        update(ui, 'Adapter translation update', accept=False)
        picker(ui, '查找文件')
        update(ui, 'Adapter translation update')
        await_release(ui, 'require("nvim-zh").translate({domain="telescope", context="title", '
                      'msgid="Find Files"}) == "文件检索"', 'ADAPTER_RESOURCES_HOT_APPLIED')
        picker(ui, '文件检索')
        git(remote, 'update-ref', 'refs/heads/main', implementation)
        update(ui, 'Adapter implementation update')
        await_release(ui, '(function() local runtime = require("nvim-zh").status().runtime; '
                      'return runtime.restart_required and not runtime.error end)()', 'ADAPTER_CODE_RESTART_REQUIRED')
        picker(ui, '文件检索')
    with Terminal(second, init, files=files) as ui:
        ui.expect('ADAPTER_RESOURCE_WORKSPACE')
        picker(ui, '搜索文件')
print('TUI=PASS adapter=telescope case=resources_update rows=32 cols=110 cancel hot-catalog frozen-code restart')
