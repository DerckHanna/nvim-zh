from adapter_tui import run

SETUP = """
require('mini.statusline').setup({ use_icons = false })
require('mini.surround').setup({})
require('mini.ai').setup({})
"""


def statusline(ui, enabled):
    ui.resize(32, 130)
    ui.command('redrawstatus!')
    ui.expect('普通' if enabled else 'Normal')


def prompts_and_feedback(ui, enabled):
    ui.command("lua vim.schedule(function() MiniSurround.user_input('Function name') end)")
    ui.expect('(mini.surround) 函数名:' if enabled else '(mini.surround) Function name:')
    ui.send('\x1b')


run('mini', {'statusline': statusline, 'prompts_and_feedback': prompts_and_feedback},
    dependencies=('NVIM_ZH_TEST_MINI',), verify=True, setup=SETUP)
