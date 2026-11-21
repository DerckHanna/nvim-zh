from adapter_tui import run

SETUP = """
vim.cmd('runtime plugin/blink-cmp.lua')
require('blink.cmp.config').merge_with({
  fuzzy = { implementation = 'lua' },
})
require('blink.cmp.lib.utils')
"""


def notifications(ui, enabled):
    ui.command('BlinkCmp build-log')
    ui.expect('没有可用的构建日志' if enabled else 'No build log available')


def health(ui, enabled):
    ui.command('checkhealth blink.cmp')
    ui.expect('系统环境' if enabled else 'System', timeout=10)
    ui.expect('补全源' if enabled else 'Sources')
    ui.expect('默认补全源' if enabled else 'Default sources')
    ui.command('q')


run('blink-cmp', {'notifications': notifications, 'health': health},
    dependencies=('NVIM_ZH_TEST_BLINK_CMP',), verify=True, setup=SETUP)
