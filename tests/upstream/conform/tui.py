from adapter_tui import run

SETUP = """
vim.cmd('runtime plugin/conform.lua')
require('conform').setup({
  formatters_by_ft = {
    lua = { 'missing_fmt' },
  },
  formatters = {
    missing_fmt = {
      command = 'missing_fmt_bin_xyz',
    },
  },
})
"""


def info_window(ui, enabled):
    ui.command('ConformInfo')
    ui.expect('日志文件：' if enabled else 'Log file:')
    ui.expect('当前 Buffer 的格式化器：' if enabled else 'Formatters for this buffer:')
    ui.expect('其他格式化器：' if enabled else 'Other formatters:')
    ui.expect("missing_fmt 不可用：未找到命令 'missing_fmt_bin_xyz'" if enabled
              else "missing_fmt unavailable: Command 'missing_fmt_bin_xyz' not found")
    ui.send('q')


def health(ui, enabled):
    ui.command('checkhealth conform')
    ui.expect('conform.nvim 报告' if enabled else 'conform.nvim report', timeout=10)
    ui.expect('日志文件：' if enabled else 'Log file:')
    ui.expect("missing_fmt 不可用：未找到命令 'missing_fmt_bin_xyz'" if enabled
              else "missing_fmt unavailable: Command 'missing_fmt_bin_xyz' not found")
    ui.command('q')


def notifications(ui, enabled):
    ui.command('edit test.lua')
    ui.command('set filetype=lua')
    ui.command("lua require('conform').format({ formatters = { 'missing_fmt' } })")
    ui.expect('lua 文件没有可用的格式化器' if enabled else 'Formatters unavailable for lua file')
    ui.command('messages')
    ui.expect("格式化器 'missing_fmt' 不可用：未找到命令 'missing_fmt_bin_xyz'" if enabled
              else "Formatter 'missing_fmt' unavailable: Command 'missing_fmt_bin_xyz' not found")
    ui.send('\r')


run('conform', {'info_window': info_window, 'health': health, 'notifications': notifications},
    dependencies=('NVIM_ZH_TEST_CONFORM',), verify=True, setup=SETUP)
