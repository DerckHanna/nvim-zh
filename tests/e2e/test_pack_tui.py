"""Real Neovim UI and vim.pack tests. Everything lives in temporary directories."""
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(os.environ['NVIM_ZH_ROOT'])
NVIM = os.environ.get('NVIM_BIN', 'nvim')


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kwargs).stdout


def index_id(files):
    value = ''.join(f'{name}\0{item["sha256"]}\0{item["size"]}\n'
                    for name, item in sorted(files.items()))
    return hashlib.sha256(value.encode()).hexdigest()


def mo(msgid, msgstr):
    # A real single-message GNU MO: no external msgfmt dependency in the test.
    original, translated = msgid.encode(), msgstr.encode()
    start = 44
    return (struct.pack('<7I', 0x950412DE, 0, 1, 28, 36, 0, 0)
            + struct.pack('<2I', len(original), start)
            + struct.pack('<2I', len(translated), start + len(original) + 1)
            + original + b'\0' + translated + b'\0')


from process_case import TempNeovimCase

class PackAndTuiTests(TempNeovimCase):
    def test_real_tui_readonly_resize_lifecycle(self):
        result = self.base / 'ui-result.json'
        self.env['NVIM_ZH_UI_RESULT'] = str(result)
        self.script(r'''
local ok, err = xpcall(function()
  vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_ROOT)
  vim.cmd('runtime plugin/nvim-zh.lua')
  local zh = require('nvim-zh')
  zh.setup({modules={core={enabled=false}}})
  local before = zh.status()
  local observed = zh.stats().runtime.observed
  local tui = require('nvim-zh.tui')
  local win = assert(zh.open())
  assert(zh.open() == win, 'duplicate panel')
  local buf = vim.api.nvim_win_get_buf(win)
  assert(not vim.bo[buf].modifiable and vim.bo[buf].buftype == 'nofile')
  local function mapping(key)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if map.lhs:lower() == key:lower() then return map.callback end
    end
  end
  assert(not mapping('u') and not mapping('b') and not mapping('e'), 'mutating panel action')
  local tab = assert(mapping('<Tab>'))
  local pages = {}
  for i=1,5 do
    tui.render()
    pages[i] = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    tab()
  end
  assert(pages[1]:find('插件运行版本',1,true))
  assert(pages[2]:find('获取可用包',1,true))
  assert(pages[3]:find('133',1,true))
  assert(pages[4]:find('没有观察到缺失',1,true))
  vim.o.columns, vim.o.lines = 28, 10
  vim.api.nvim_exec_autocmds('VimResized', {})
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf,0,-1,false)) do
    assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(win), 'wide line overflow')
  end
  vim.api.nvim_exec_autocmds('ColorScheme', {})
  assert(zh.stats().runtime.observed == observed, 'panel changed translation statistics')
  assert(zh.status().version.active_bundle == before.version.active_bundle)
  assert(vim.deep_equal(zh.status().config,before.config))
  tui.close()
  assert(not vim.api.nvim_win_is_valid(win) and not vim.api.nvim_buf_is_valid(buf))
  win = assert(zh.open())
  vim.api.nvim_win_close(win,true)
  vim.wait(600,function() return false end,20)
  assert(#vim.api.nvim_get_autocmds({group='NvimZhRuntime'}) > 0)
  vim.fn.writefile({vim.json.encode({ok=true,pages=5})},vim.env.NVIM_ZH_UI_RESULT)
end,debug.traceback)
if not ok then vim.fn.writefile({vim.json.encode({ok=false,error=err})},vim.env.NVIM_ZH_UI_RESULT) end
vim.defer_fn(function() vim.cmd('qa!') end,200)
''')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        proc = subprocess.Popen([NVIM, '-u', 'NONE', '-i', 'NONE', '-n',
                                 '-c', 'lua dofile(vim.env.NVIM_ZH_SPEC)'], env=self.env,
                                stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        screen = bytearray()
        try:
            deadline = time.monotonic() + 40
            while proc.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        screen.extend(os.read(master, 65536))
                    except OSError:
                        break
            proc.wait(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait()
            os.close(master)
        self.assertTrue(result.exists(), screen.decode(errors='replace')[-3000:])
        report = json.loads(result.read_text())
        self.assertTrue(report['ok'], report.get('error'))

    def test_actual_pack_confirm_cancel_update_code_and_rollback(self):
        major, minor = json.loads(run([NVIM, '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
            '+lua io.stdout:write(vim.json.encode({vim.version().major,vim.version().minor}))', '+qa!'], env=self.env))
        if (major, minor) < (0, 12):
            self.skipTest('vim.pack requires Neovim 0.12; UI/config tests remain applicable')
        remote = self.base / 'remote'
        shutil.copytree(ROOT, remote, ignore=shutil.ignore_patterns('.git', '.agents', '.codex', '.aws', 'build', 'tests', '__pycache__'))
        git = lambda *args: run(['git', '-C', str(remote), *args])
        git('init', '-b', 'main')
        git('config', 'user.name', 'nvim-zh fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        git('add', '.'); git('commit', '-m', 'initial')
        initial = git('rev-parse', 'HEAD').strip()
        payload = remote / 'resources'
        manifest_path = payload / 'manifest.json'
        original_manifest = json.loads(manifest_path.read_text())
        catalog_path = payload / 'catalogs/nvim-ui.json'
        catalog = json.loads(catalog_path.read_text())
        entry = next(e for e in catalog['entries'] if e['msgid'] == 'No information available')
        entry['msgstr'] = '来自包管理器的新译文'
        catalog_path.write_text(json.dumps(catalog, ensure_ascii=False))
        help_path = payload / 'help/doc/nvim-zh.cnx'
        help_path.write_text(help_path.read_text() + '\nPACK_RESOURCE_MARKER\n')
        summary_path = payload / 'summary.json'
        summary = json.loads(summary_path.read_text())
        summary['native']['probe']['msgstr'] = '来自包管理器的欢迎译文'
        summary_path.write_text(json.dumps(summary, ensure_ascii=False))
        native = payload / 'native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
        native.write_bytes(mo(summary['native']['probe']['msgid'], summary['native']['probe']['msgstr']))
        new_manifest = copy.deepcopy(original_manifest)
        for name in new_manifest['bundle']['files']:
            data = (payload / name).read_bytes()
            new_manifest['bundle']['files'][name] = {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
        new_manifest['bundle']['id'] = index_id(new_manifest['bundle']['files'])
        manifest_path.write_text(json.dumps(new_manifest))
        git('add', '.'); git('commit', '-m', 'translation resources')
        translated = git('rev-parse', 'HEAD').strip()
        implementation_path = remote / 'lua/nvim-zh/ui.lua'
        implementation_path.write_text(implementation_path.read_text() + '\n-- fixture implementation revision\n')
        for name in new_manifest['implementation']['files']:
            data = (remote / name).read_bytes()
            new_manifest['implementation']['files'][name] = {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
        new_manifest['implementation']['id'] = index_id(new_manifest['implementation']['files'])
        manifest_path.write_text(json.dumps(new_manifest))
        git('add', '.'); git('commit', '-m', 'implementation')
        implementation = git('rev-parse', 'HEAD').strip()
        catalog_path.write_text('corrupt resource')
        git('add', '.'); git('commit', '-m', 'invalid fixture release')
        broken = git('rev-parse', 'HEAD').strip()
        git('reset', '--hard', initial)
        fixture = dict(remote=str(remote), initial=initial, translated=translated,
                       implementation=implementation, broken=broken)
        (self.base / 'fixture.json').write_text(json.dumps(fixture))
        self.env['NVIM_ZH_PACK_FIXTURE'] = str(self.base / 'fixture.json')
        script = self.script(r'''
local f = vim.json.decode(table.concat(vim.fn.readfile(vim.env.NVIM_ZH_PACK_FIXTURE),'\n'))
vim.pack.add({{src='file://' .. f.remote,name='renamed-zh',version='main'}},{confirm=false,load=true})
local zh = require('nvim-zh')
zh.setup()
assert(vim.wait(20000,function() return zh.status().runtime.status~='syncing' end,20))
assert(zh.status().runtime.status~='error' and zh.status().version.active_bundle,vim.inspect(zh.status()))
local probe='type  :help nvim<Enter>     if you are new! '
local native_enabled=zh.status().native.active
if vim.env.NVIM_ZH_TEST_NATIVE_RUNTIME == '1' then
  assert(native_enabled, 'explicit native vim.pack run did not activate gettext')
end
if not native_enabled then print('VIM_PACK_NATIVE=SKIP native locale capability unavailable') end
local running=zh.status().version.running_implementation
local old_bundle=zh.status().version.active_bundle
local function restart_probe(expect_error)
  local script=vim.fn.tempname() .. '.lua'
  vim.fn.writefile({
    "vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_INSTALLED_PATH)",
    "local z=require('nvim-zh'); z.setup({modules={core={enabled=false}}})",
    "assert(z.status().version.active_bundle, vim.inspect(z.status().runtime))",
    "assert(not z.status().runtime.restart_required, 'restart still pending')",
    expect_error and "assert(z.status().runtime.status=='error', 'broken installed resources not reported')" or
      "assert(z.status().runtime.status=='ok', vim.inspect(z.status().runtime))",
    "print('RESTART_SYNC=PASS')",
  },script)
  local result=vim.system({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-n','-l',script},
    {env={NVIM_ZH_INSTALLED_PATH=require('nvim-zh.paths').root}}):wait(30000)
  vim.fn.delete(script)
  assert(result.code==0,(result.stdout or '') .. (result.stderr or ''))
  assert(((result.stdout or '') .. (result.stderr or '')):find('RESTART_SYNC=PASS',1,true))
end
local function move(rev)
  local p=vim.system({'git','-C',f.remote,'reset','--hard',rev}):wait()
  assert(p.code==0,p.stderr)
end
local function update(accept, ready)
  local gen=zh.status().runtime.generation
  vim.pack.update({'renamed-zh'})
  assert(vim.bo.filetype=='nvim-pack','missing standard confirmation buffer')
  if accept then vim.cmd.write() else vim.cmd.quit() end
  if accept then
    -- A refresh triggered while entering or leaving the confirmation tab can
    -- finish before the refresh that observes the confirmed package revision.
    assert(vim.wait(20000,function()
      local status=zh.status()
      return status.runtime.generation>gen and status.runtime.status~='syncing' and ready(status)
    end,20),vim.inspect(zh.status()))
  else vim.wait(300,function() return false end,20) end
end
move(f.translated)
update(false)
assert(zh.status().version.active_bundle==old_bundle,'cancel activated resources')
assert(zh.translate({domain='nvim-ui',msgid='No information available'})=='没有可用的信息')
update(true,function(s) return s.version.active_bundle~=old_bundle end)
assert(zh.translate({domain='nvim-ui',msgid='No information available'})=='来自包管理器的新译文')
assert(zh.status().version.active_bundle~=old_bundle)
vim.cmd('help nvim-zh')
assert(table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'\n'):find('PACK_RESOURCE_MARKER',1,true),'Help did not update')
if native_enabled then assert(vim.fn.gettext(probe)=='来自包管理器的欢迎译文','MO did not update') end
local new_bundle=zh.status().version.active_bundle
move(f.implementation); update(true,function(s) return s.runtime.restart_required end)
assert(zh.status().runtime.restart_required,'implementation update not reported')
assert(zh.status().version.running_implementation==running,'running implementation changed')
assert(zh.status().version.installed_implementation~=running)
restart_probe(false)
move(f.broken); update(true,function(s) return s.runtime.status=='error' end)
assert(zh.status().runtime.status=='error','corrupt release marked success')
assert(zh.status().version.active_bundle==new_bundle,'corrupt release replaced good resources')
restart_probe(true)
move(f.initial); update(true,function(s)
  return s.version.active_bundle==old_bundle and not s.runtime.restart_required
end)
assert(zh.status().version.active_bundle==old_bundle,'package rollback did not restore complete resource set')
assert(zh.translate({domain='nvim-ui',msgid='No information available'})=='没有可用的信息')
if native_enabled then assert(vim.fn.gettext(probe)~='来自包管理器的欢迎译文','MO rollback failed') end
assert(not zh.status().runtime.restart_required)
print('VIM_PACK_INTEGRATION=PASS renamed_package standard_confirm cancel ui_help_mo_update frozen_code corrupt_release rollback native=' .. tostring(native_enabled))
''')
        process = subprocess.run([NVIM, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', str(script)],
                                 env=self.env, capture_output=True, text=True, timeout=60)
        output = process.stdout + process.stderr
        self.assertEqual(process.returncode, 0, output)
        self.assertIn('VIM_PACK_INTEGRATION=PASS', output)
        if os.environ.get('NVIM_ZH_TEST_NATIVE_RUNTIME') == '1':
            self.assertIn('native=true', output)
        print(output[output.index('VIM_PACK_INTEGRATION=PASS'):].splitlines()[0])



if __name__ == '__main__':
    unittest.main(verbosity=2)
