"""Drive package management with actual Neovim keystrokes and offline release fixtures."""
import json
from pathlib import Path
import re
import tempfile
import unittest

from adapter_tui import ROOT, Terminal, lua_literal
from pack_assets import assets
from resource_bundle import digest, encoded


def choose(ui, label):
    frame = ui.expect(': ' + label + '\n')
    match = re.search(r'^\s*(\d+): ' + re.escape(label) + '$', frame, re.M)
    if not match:
        raise AssertionError(f'No choice for {label!r}\n{frame}')
    ui.send(match[1] + '\r')


class PackageManagementTests(unittest.TestCase):
    def test_install_update_and_offline_rollback(self):
        with tempfile.TemporaryDirectory(prefix='nvim-zh-packs-tui-') as directory:
            base = Path(directory)
            asset_name, original, first = next(assets(ROOT, '1.0.0',
                                                      'https://github.com/DerckHanna/nvim-zh', 'telescope'))
            changed = json.loads(original)
            changed['manifest']['version'] = '1.1.0'
            changed['catalog']['entries']['title']['Find Files'] = '文件检索'
            update = encoded(changed)
            second = {**first, 'version': '1.1.0', 'size': len(update), 'sha256': digest(update),
                      'url': first['url'].replace('v1.0.0', 'v1.1.0')}
            initial_file, update_file = base / asset_name, base / 'update.json'
            initial_file.write_bytes(original)
            update_file.write_bytes(update)
            index = base / 'catalog.json'
            index.write_bytes(encoded({'schema': 1, 'packages': [first]}))
            requests = base / 'requests'
            init = f"""
vim.opt.runtimepath:prepend({lua_literal(str(ROOT))})
vim.cmd('runtime plugin/nvim-zh.lua')
local zh = require('nvim-zh')
zh.setup({{modules={{core={{enabled=false}}}}}})
assert(not next(zh.status().packs) and not next(zh.status().adapters))
vim.api.nvim_buf_set_lines(0, 0, -1, false, {{'PACK_WORKSPACE'}})
local index, request_log = {lua_literal(str(index))}, {lua_literal(str(requests))}
local files = {{
  [{lua_literal(first['url'])}] = {lua_literal(str(initial_file))},
  [{lua_literal(second['url'])}] = {lua_literal(str(update_file))},
}}
local pack_get = vim.pack.get
vim.pack.get = function(...)
  if PackTarget then
    return {{{{ spec = {{ src = {lua_literal(first['repository'])} }}, rev = {lua_literal(first['targets'][0])} }}}}
  end
  return pack_get(...)
end
local system = vim.system
vim.system = function(argv, opts, on_exit)
  if argv[1] ~= 'curl' then return system(argv, opts, on_exit) end
  local url, output
  for i, arg in ipairs(argv) do
    if arg == '--url' then url = argv[i+1] end
    if arg == '--output' then output = argv[i+1] end
  end
  vim.fn.writefile({{url}}, request_log, 'a')
  local cancelled = false
  local source = url:match('/packs/catalog%.json$') and index or files[url]
  vim.defer_fn(function()
    if source and not cancelled then vim.uv.fs_copyfile(source, output); on_exit({{code=0}})
    else on_exit({{code=1, stderr='fixture offline'}}) end
  end, 120)
  return {{kill=function() cancelled = true end}}
end
function PackCheck(version, text)
  local pack = assert(zh.status().packs.telescope)
  assert(pack.active == version and pack.selected == version, vim.inspect(pack))
  assert(zh.translate({{domain='telescope', context='title', msgid='Find Files'}}) == text)
  assert(not package.loaded['telescope'], 'target was forced to load')
  print('PACK_CHECK_' .. version)
end
"""
            with Terminal(base, init) as ui:
                ui.expect('PACK_WORKSPACE')
                ui.command('NvimZh')
                ui.expect('Enter 管理')
                ui.send('\t')
                ui.expect('[汉化包]', '联网刷新目录')
                self.assertFalse(requests.exists(), 'opening the panel requested the remote index')
                ui.send('\r')
                ui.expect('telescope', '待验证')
                ui.send('/telescope\r')
                ui.expect('查找 telescope')
                ui.send('\r')
                choose(ui, '选择发行版本')
                choose(ui, '1.0.0 · 显式选择')
                ui.send('q')
                ui.expect('PACK_WORKSPACE')
                ui.command('NvimZhPacks')
                ui.expect('1.0.0', 'telescope')
                ui.command("lua PackCheck('1.0.0','查找文件')")
                ui.expect('PACK_CHECK_1.0.0')
                ui.command('lua PackTarget = true')
                index.write_bytes(encoded({'schema': 1, 'packages': [first, second]}))
                ui.send('r')
                ui.expect('可更新', '1.1.0')
                ui.resize(24, 55)
                ui.expect('1.1.0')
                ui.send('u')
                ui.expect('已生效', '1.1.0')
                ui.command("lua PackCheck('1.1.0','文件检索')")
                ui.expect('PACK_CHECK_1.1.0')
                ui.send('\r')
                choose(ui, '回滚至 1.0.0')
                choose(ui, '回滚')
                ui.command("lua PackCheck('1.0.0','查找文件')")
                ui.expect('PACK_CHECK_1.0.0')
                ui.send('\r')
                choose(ui, '暂停')
                ui.expect('已暂停')
                ui.send('\r')
                choose(ui, '恢复')
                ui.expect('可更新 1.0.0')
                ui.command("lua PackCheck('1.0.0','查找文件')")
                ui.expect('PACK_CHECK_1.0.0')
                ui.send('\r')
                choose(ui, '卸载')
                choose(ui, '取消')
                ui.expect('可更新 1.0.0')
                ui.send('\r')
                choose(ui, '卸载')
                choose(ui, '卸载 telescope')
                ui.command("lua assert(not require('nvim-zh').status().packs.telescope); print('PACK_TEST_DONE')")
                ui.expect('PACK_TEST_DONE')
            self.assertEqual([url for url in requests.read_text().splitlines() if '/releases/' in url],
                             [first['url'], second['url']])


if __name__ == '__main__':
    unittest.main(verbosity=2)
