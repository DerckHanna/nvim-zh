from adapter_tui import run

SETUP = """
require('gitsigns').setup({})
"""


def messages(ui, enabled):
    ui.command('Gitsigns invalid_action_xyz')
    ui.expect('invalid_action_xyz 不是有效的函数或动作' if enabled
              else 'invalid_action_xyz is not a valid function or action')


def popups(ui, enabled):
    ui.command(
        "lua require('gitsigns.popup').create("
        "{{{'Hunk 1 of 2', 'Title'}}, {{'Loading...', 'Title'}}}, "
        "{ relative = 'editor', row = 2, col = 2, width = 30, height = 4 }, 'hunk')"
    )
    ui.expect('第 1 / 2 个 Hunk' if enabled else 'Hunk 1 of 2')
    ui.expect('正在加载...' if enabled else 'Loading...')
    ui.command("lua require('gitsigns.popup').close('hunk')")


run('gitsigns', {'messages': messages, 'popups': popups},
    dependencies=('NVIM_ZH_TEST_GITSIGNS',), verify=True, setup=SETUP)
