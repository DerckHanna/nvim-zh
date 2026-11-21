from adapter_tui import run

SETUP = """
require('snacks').setup({
  dashboard = {
    enabled = true,
    sections = {
      { section = 'header' },
      { section = 'keys', gap = 1, padding = 1 },
    },
  },
  picker = { enabled = true },
  input = { enabled = true },
  notifier = { enabled = false },
})
"""


def dashboard(ui, enabled):
    ui.command('lua Snacks.dashboard.open()')
    ui.expect('查找文件' if enabled else 'Find File')
    ui.expect('最近文件' if enabled else 'Recent Files')
    ui.expect('退出' if enabled else 'Quit')


def picker_and_ui(ui, enabled):
    ui.command("lua Snacks.picker.pick({ source = 'buffers', items = { { text = 'demo.lua' } }, show_empty = true })")
    ui.expect('Buffer 列表' if enabled else 'Buffers')
    ui.send('\x1b')


def health(ui, enabled):
    ui.command('checkhealth snacks')
    ui.expect('已调用 setup' if enabled else 'setup called', timeout=10)
    ui.expect('初始化配置 {enabled}' if enabled else 'setup {enabled}')
    ui.expect('初始化已执行' if enabled else 'setup ran')
    ui.send('/vim\\.ui\\.input\r')
    ui.expect('vim.ui.input 已设置为 Snacks.input' if enabled
              else 'vim.ui.input is set to Snacks.input')
    ui.command('q')


run('snacks', {'dashboard': dashboard, 'picker_and_ui': picker_and_ui, 'health': health},
    dependencies=('NVIM_ZH_TEST_SNACKS',), verify=True, setup=SETUP)
