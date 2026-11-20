"""Exercise versioned Telescope pack updates in the real TUI."""
import json
from pathlib import Path
import sys
import tempfile

from adapter_tui import ROOT, Terminal, init_for
from pack_assets import assets
from resource_bundle import descriptor, encoded


def candidate(base, original, version, translation, *, code=False):
    asset = json.loads(original)
    asset['manifest']['version'] = version
    asset['files']['catalogs/zh_CN.json'] = asset['files']['catalogs/zh_CN.json'].replace('查找文件', translation)
    if code:
        asset['files']['adapter/entry.lua'] += '\n-- Changed implementation for the restart test.\n'
    asset['manifest']['files'] = descriptor({name: value.encode() for name, value in asset['files'].items()})
    path = base / (version + '.json')
    path.write_bytes(encoded(asset))
    return path


def picker(ui, title):
    ui.command('Telescope find_files')
    ui.expect(title, 'resource-fixture.txt')
    ui.send(b'\x1b\x1b')
    ui.expect('ADAPTER_RESOURCE_WORKSPACE', reject=(title,))


def import_pack(ui, path):
    ui.command('NvimZhPacks! import ' + str(path))


assert sys.argv[1] == 'resources_update'
with tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-resources-tui-') as directory:
    temp = Path(directory)
    _, original, _ = next(assets(ROOT, '1.0.0', 'https://example.invalid/nvim-zh', 'telescope'))
    translated = candidate(temp, original, '1.1.0', '文件检索')
    implementation = candidate(temp, original, '1.2.0', '搜索文件', code=True)
    init = init_for('telescope', True, """
vim.cmd('runtime plugin/nvim-zh.lua')
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
        import_pack(ui, translated)
        picker(ui, '文件检索')
        import_pack(ui, implementation)
        ui.expect('重启后应用选定版本')
        picker(ui, '文件检索')
    with Terminal(second, init, files=files) as ui:
        ui.expect('ADAPTER_RESOURCE_WORKSPACE')
        picker(ui, '搜索文件')
print('TUI=PASS adapter=telescope case=resources_update hot-catalog frozen-code restart')
