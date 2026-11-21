from adapter_tui import run

SETUP = """
require('cmake-tools').setup({})
"""


def notifications(ui, enabled):
    ui.command("lua require('cmake-tools.log').error('You need to configure it first')")
    ui.expect('请先执行 CMake 配置' if enabled else 'You need to configure it first')


def prompts(ui, enabled):
    ui.command("lua vim.fn.writefile({'cmake_minimum_required(VERSION 3.16)', 'project(demo)'}, 'CMakeLists.txt')")
    ui.command("lua require('cmake-tools').setup({})")
    ui.command("lua require('cmake-tools').select_build_type(function() end)")
    ui.expect('选择构建类型' if enabled else 'Select build type')
    ui.send('\r')


run('cmake-tools', {'notifications': notifications, 'prompts': prompts},
    dependencies=('NVIM_ZH_TEST_PLENARY', 'NVIM_ZH_TEST_CMAKE_TOOLS'), verify=True, setup=SETUP)
