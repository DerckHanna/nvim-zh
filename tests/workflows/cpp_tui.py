"""Run the same C++ editing, building and debugging job with Chinese on and off."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from adapter_tui import Terminal, lua_literal
from pack_assets import assets
from pack_fixture import seed

ROOT = Path(os.environ['NVIM_ZH_ROOT'])
SOURCE = """int main() {
    int counter = 7; // 搜索标记
    return counter == 7 ? 0 : 1
}
"""
MAKEFILE = """app: 练习.cpp
	$(CXX) -std=c++17 -g -O0 -Wall -o app 练习.cpp
"""

SETUP = """
vim.opt.loadplugins = false
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_ROOT)
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_TEST_NVIM_DAP)
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_TEST_NVIM_DAP_VIEW)
vim.cmd('runtime plugin/nvim-zh.lua')
vim.cmd('runtime plugin/dap.lua')
vim.cmd('runtime plugin/dap-view.lua')
vim.o.shortmess = 'I'
vim.o.winborder = 'single'
vim.o.shell = '/bin/bash'
vim.o.shellcmdflag = '-o pipefail -c'
local zh = require('nvim-zh')
zh.register_adapter_source('nvim-dap-view', vim.env.NVIM_ZH_TEST_NVIM_DAP_VIEW)
local enabled = vim.env.NVIM_ZH_LANGUAGE == 'on'
zh.setup({ modules = { core = { enabled = false }, help = { enabled = enabled },
  diagnostics = { enabled = enabled }, lsp = { hints = enabled }, plugins = { auto = enabled } } })
local dap = require('dap')
dap.adapters.codelldb = { type = 'executable', command = 'codelldb' }
dap.configurations.cpp = {{ name = 'C++ workspace', type = 'codelldb', request = 'launch',
  cwd = vim.uv.cwd(), program = vim.uv.cwd() .. '/app', terminal = 'integrated' }}
require('dap-view').setup({auto_toggle = 'keep_terminal', winbar = { default_section = 'scopes' }})
Cpp = {}
dap.listeners.after.event_exited.workflow = function(_, body) Cpp.exit = body.exitCode end

function Cpp.start_lsp()
  vim.bo.filetype = 'cpp'
  Cpp.id = assert(vim.lsp.start({ name = 'clangd',
    cmd = { vim.env.NVIM_ZH_TEST_CLANGD, '--background-index=false', '--log=error' },
    root_dir = vim.uv.cwd() }))
  assert(vim.wait(10000, function() return #vim.diagnostic.get(0) > 0 end, 25))
  local diag = vim.diagnostic.get(0)[1]
  Cpp.raw = vim.deepcopy(diag.user_data.lsp)
  print('LSP_READY')
end

function Cpp.original()
  print(Cpp.raw.code .. ': ' .. Cpp.raw.message)
end

function Cpp.capture(path)
  local items = vim.fn.getqflist()
  local item = vim.iter(items):find(function(value) return value.valid == 1 end)
  assert(item, vim.inspect(items))
  assert(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(item.bufnr), ':t') == '练习.cpp')
  local data = { shell_error = vim.v.shell_error, lnum = item.lnum, col = item.col, text = item.text }
  assert(data.shell_error ~= 0 and data.lnum == 3, vim.inspect(data))
  vim.fn.writefile({ vim.json.encode({ compiler = data, lsp = Cpp.raw }) }, path)
  print('BUILD_CAPTURED')
end
vim.schedule(function() print('CPP_READY') end)
"""


def lua(ui, command):
    ui.command('lua ' + command)


def dismiss(ui):
    ui.send(b'\r')
    ui.pump(.1)


def run(base, code, enabled):
    os.environ['NVIM_ZH_LANGUAGE'] = 'on' if enabled else 'off'
    os.environ['XDG_DATA_HOME'] = str(base / 'data')
    seed(ROOT, base / 'data', verified_tools=True)
    mode = 'zh' if enabled else 'en'
    with Terminal(base, SETUP, rows=40, cols=142, files={'练习.cpp': SOURCE, 'Makefile': MAKEFILE}) as ui:
        ui.expect('CPP_READY')
        ui.command('help nvim-zh-cpp')
        ui.expect('C/C++ 工作流' if enabled else 'C/C++ WORKFLOW')
        ui.command('close')
        ui.command('help quickfix')
        lua(ui, "print(vim.fn.expand('%:t'))")
        ui.expect('quickfix.cnx' if enabled else 'quickfix.txt')
        ui.command('close')
        ui.command('vimgrep /搜索标记/ *.cpp')
        ui.expect('搜索标记', '练习.cpp')
        ui.command('compiler gcc')
        lua(ui, 'Cpp.start_lsp()')
        ui.expect('LSP_READY', timeout=12)
        ui.command('3')
        lua(ui, "vim.diagnostic.open_float({scope='buffer'})")
        ui.expect("return 语句后缺少 ';'" if enabled else "Expected ';' after return statement")
        ui.send(b'\x1b')
        lua(ui, 'Cpp.original()')
        ui.expect("expected_semi_after_stmt: Expected ';' after return statement")
        ui.command('make!')
        ui.expect('Error', 'Press ENTER', timeout=15)
        dismiss(ui)
        report = base / 'protocol.json'
        lua(ui, f'Cpp.capture({lua_literal(str(report))})')
        ui.expect('BUILD_CAPTURED')
        ui.command('copen')
        ui.expect('练习.cpp')
        ui.command('cc')
        lua(ui, "assert(vim.fn.line('.') == 3); print('JUMP_3')")
        ui.expect('JUMP_3')
        lua(ui, "vim.lsp.buf.code_action({context={diagnostics={Cpp.raw},only={'quickfix'}}})")
        frame = ui.expect("插入 ';'" if enabled else "insert ';'")
        number = re.search(r"(\d+): .*';'", frame)
        assert number is not None, frame
        ui.send(number[1] + '\r')
        ui.expect('return counter == 7 ? 0 : 1;')
        ui.command('write')
        ui.command('make!')
        ui.expect('Press ENTER', timeout=15)
        dismiss(ui)
        lua(ui, "assert(vim.v.shell_error == 0 and vim.uv.fs_stat('app')); print('BUILD_EXIT_0')")
        ui.expect('BUILD_EXIT_0')
        ui.command('3')
        ui.command('DapToggleBreakpoint')
        ui.command('DapContinue')
        ui.expect('counter = 7', '变量' if enabled else 'Scopes', timeout=18)
        lua(ui, "assert(require('dap').session().current_frame.line == 3); print('BREAKPOINT_3')")
        ui.expect('BREAKPOINT_3')
        ui.command('DapContinue')
        lua(ui, "assert(vim.wait(8000,function() return Cpp.exit == 0 end)); print('DAP_EXIT_0')")
        ui.expect('DAP_EXIT_0', timeout=10)
        ui.command('DapViewClose')
        ui.command('edit 练习.cpp')
        if enabled:
            lua(ui, "Cpp.version=vim.lsp.get_client_by_id(Cpp.id).server_info.version; "
                "vim.lsp.get_client_by_id(Cpp.id).server_info.version='unknown test version'")
            ui.command('NvimZh')
            ui.expect('C/C++', '版本未经验证')
            ui.send('q')
            lua(ui, "vim.lsp.get_client_by_id(Cpp.id).server_info.version=Cpp.version")
            ui.command('NvimZhPacks import ' + str(code))
            lua(ui, "assert(require('nvim-zh').status().packs.clangd.active=='1.1.0'); print('PACK_UPDATED')")
            ui.expect('PACK_UPDATED')
            ui.command('NvimZhPacks rollback clangd')
            lua(ui, "assert(require('nvim-zh').status().packs.clangd.active=='1.0.0'); print('PACK_ROLLED_BACK')")
            ui.expect('PACK_ROLLED_BACK')
        evidence = json.loads(report.read_text())
        assert (ui.cwd / '练习.cpp').read_text() == SOURCE.replace(': 1\n', ': 1;\n')
        evidence['build_exit'] = 0
        evidence['dap_exit'] = 0
        print(f'CPP_TUI=PASS locale={mode} make qf_jump code_action breakpoint variables continue', flush=True)
        return evidence


if __name__ == '__main__':
    for tool, args in [('clangd', ['--version']), ('g++', ['--version']), ('make', ['--version'])]:
        print(subprocess.check_output([tool, *args], text=True).splitlines()[0])
    observations = []
    with tempfile.TemporaryDirectory(prefix='nvim-zh-cpp-') as directory:
        root = Path(directory)
        code = root / 'clangd-1.1.0.json'
        _, content, _ = next(assets(ROOT, '1.1.0', 'https://example.invalid/nvim-zh', 'clangd'))
        code.write_bytes(content)
        for name, enabled in [('英文项目', False), ('中文项目', True)]:
            base = root / name
            base.mkdir()
            observations.append(run(base, code, enabled))
        assert observations[0] == observations[1], observations
        print('CPP_TUI_DIFFERENTIAL=PASS compiler_and_lsp_data_equal ' + json.dumps(observations[0], ensure_ascii=False))
