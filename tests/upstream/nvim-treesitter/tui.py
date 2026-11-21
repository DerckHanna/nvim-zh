from adapter_tui import run

SETUP = """
vim.cmd('runtime plugin/nvim-treesitter.lua')
require('nvim-treesitter').setup({})
"""


def notifications(ui, enabled):
    ui.command('TSInstall nonexistent_lang_xyz')
    ui.expect('跳过不支持的语言：nonexistent_lang_xyz' if enabled
              else 'skipping unsupported language: nonexistent_lang_xyz')


def health(ui, enabled):
    ui.command('checkhealth nvim-treesitter')
    ui.expect('依赖要求' if enabled else 'Requirements', timeout=10)
    ui.expect('操作系统信息' if enabled else 'OS Info')
    ui.expect('解析器与查询文件的安装目录' if enabled else 'Install directory for parsers and queries')
    ui.expect('已安装的语言' if enabled else 'Installed languages')
    ui.command('q')


run('nvim-treesitter', {'notifications': notifications, 'health': health},
    dependencies=('NVIM_ZH_TEST_NVIM_TREESITTER',), verify=True, setup=SETUP)
