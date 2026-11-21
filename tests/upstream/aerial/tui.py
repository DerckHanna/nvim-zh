from adapter_tui import run

SETUP = """
require('aerial').setup({
  backends = { 'lsp', 'markdown' },
  layout = { min_width = 40 },
})
"""


def outline_window(ui, enabled):
    ui.command('edit sample.txt')
    ui.command('set filetype=text')
    ui.command('AerialOpen')
    ui.expect('暂无符号' if enabled else 'No symbols')
    ui.expect('lsp (不支持)' if enabled else 'lsp (not supported)')
    ui.send('g?')
    ui.expect('显示默认键映射' if enabled else 'Show default keymaps')
    ui.expect('关闭 Aerial Window' if enabled else 'Close the aerial window')
    ui.send('q')
    ui.command('AerialClose')


def command_info(ui, enabled):
    ui.command('edit sample.txt')
    ui.command('set filetype=text')
    ui.command('AerialInfo')
    ui.expect('Aerial 信息' if enabled else 'Aerial Info')
    ui.expect('已配置的后端：' if enabled else 'Configured backends:')
    ui.expect('lsp (不支持) [未找到支持符号的 LSP 客户端]' if enabled
              else 'lsp (not supported) [No LSP client found that supports symbols]')
    ui.send('\r')


run('aerial', {'outline_window': outline_window, 'command_info': command_info},
    dependencies=('NVIM_ZH_TEST_AERIAL',), verify=True, setup=SETUP)
