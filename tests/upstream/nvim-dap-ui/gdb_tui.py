"""Drive a real GDB DAP session. Requires GDB with DAP and permission to trace its child."""
from adapter_tui import run


def gdb_session(ui, enabled):
    ui.command('lua StartGdbFixture()')
    condition = 'fixture_counter == 7'
    label = '条件：' if enabled else 'Condition:'
    ui.expect('fixture_counter volatile int = 7', label + ' ' + condition, timeout=15)
    ui.command('lua require("dap").step_over()')
    ui.expect('fixture_counter volatile int = 8', timeout=15)
    ui.command('lua require("dap").list_breakpoints(true)')
    ui.expect(('条件：' if enabled else 'Condition: ') + condition,
              reject=('Condition: ' + condition,) if enabled else ('条件：',))
    ui.command('cclose')
    ui.command('lua require("dap").continue()')
    ui.command('lua assert(vim.wait(10000, function() return require("dap").session() == nil end)); '
               'print("GDB_SESSION_TERMINATED")')
    ui.expect('GDB_SESSION_TERMINATED', timeout=15)


run('nvim-dap-ui', {'gdb_session': gdb_session},
    dependencies=('NVIM_ZH_TEST_NVIM_DAP', 'NVIM_ZH_TEST_NVIM_NIO', 'NVIM_ZH_TEST_NVIM_DAP_UI'),
    verify=True,
    files={'gdb-fixture.c': '''int main(void) {
  volatile int fixture_counter = 7;
  fixture_counter++;
  return fixture_counter - 8;
}
'''},
    setup="""
vim.opt.shortmess:append('F')
zh.register_adapter_source('nvim-dap', assert(vim.env.NVIM_ZH_TEST_NVIM_DAP))
vim.cmd('runtime plugin/dap.lua')
require('dapui').setup()
function StartGdbFixture()
  local cwd = vim.uv.cwd()
  local file, program = cwd .. '/gdb-fixture.c', cwd .. '/gdb-fixture'
  local compiled = vim.system({ 'cc', '-O0', '-g', file, '-o', program }, { text = true }):wait()
  assert(compiled.code == 0, compiled.stderr)
  local dap, dapui = require('dap'), require('dapui')
  dap.adapters.gdb = {
    type = 'executable',
    command = vim.env.NVIM_ZH_TEST_GDB or 'gdb',
    args = { '-nx', '--interpreter=dap', '-iex', 'set debuginfod enabled off',
      '-iex', 'set disable-randomization off' },
  }
  vim.cmd('silent edit ' .. vim.fn.fnameescape(file))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  dap.set_breakpoint('fixture_counter == 7')
  dapui.open()
  dapui.elements.watches.add('fixture_counter')
  dap.run({ name = 'GDB fixture', type = 'gdb', request = 'launch', program = program, cwd = cwd })
end
""")
