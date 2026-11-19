import re

from adapter_tui import run


def layout(ui, enabled):
    ui.command('lua require("dapui").open()')
    ui.expect('没有监视表达式' if enabled else 'No Expressions')
    ui.resize(24, 86)
    ui.expect('没有监视表达式' if enabled else 'No Expressions')
    ui.command('lua require("dapui").close()')
    ui.command('lua require("dapui").open()')
    ui.expect('没有监视表达式' if enabled else 'No Expressions')


def selection(ui, enabled):
    ui.command('lua require("dapui").float_element()')
    frame = ui.expect('选择元素：' if enabled else 'Select an element:', '监视' if enabled else 'Watches')
    watch = re.search(r'(\d+): (?:监视|watches|Watches)\b', frame)
    assert watch, frame
    ui.send(watch[1] + '\r')
    ui.expect('没有监视表达式' if enabled else 'No Expressions')


def notification(ui, enabled):
    ui.command('lua require("dapui").eval("fixture_expression")')
    ui.expect('没有活动的调试会话' if enabled else 'No active debug session')


def window_prompt(ui, enabled):
    ui.command('split')
    ui.command('lua local id = require("dapui.util").select_win(); '
               'print(vim.api.nvim_win_is_valid(id) and "DAP_UI_WINDOW_SELECTED")')
    ui.expect('选择 Window：' if enabled else 'Select window:')
    ui.send('a')
    ui.expect('DAP_UI_WINDOW_SELECTED')


def mappings(ui, enabled):
    ui.command('lua require("dapui").open()')
    ui.expect('没有监视表达式' if enabled else 'No Expressions')
    ui.command('lua FixturePrintMapping()')
    ui.expect('ACTION=展开' if enabled else 'ACTION=expand')


def value_display(ui, enabled):
    ui.command('lua local lines = require("dapui.util").format_value(1, "one\\ntwo\\nthree\\nfour"); '
               'print(table.concat(lines, " | "))')
    ui.expect('还有' if enabled else 'more lines')


def help_topic(ui, enabled):
    ui.command('lua AdapterTestHelpTags()')
    ui.command('help dapui.setup()')
    ui.expect('配置 nvim-dap-ui' if enabled else 'Configure nvim-dap-ui')
    # Tags and field names stay intact.
    ui.expect('dapui.Config', 'user_config')


run('nvim-dap-ui', {'layout': layout, 'selection': selection, 'notification': notification,
                    'window_prompt': window_prompt, 'mappings': mappings, 'value_display': value_display,
                    'help': help_topic},
    dependencies=('NVIM_ZH_TEST_NVIM_DAP', 'NVIM_ZH_TEST_NVIM_NIO', 'NVIM_ZH_TEST_NVIM_DAP_UI'),
    verify=True,
    setup="""
vim.cmd('runtime plugin/dap.lua')
require('dapui').setup({ icons = { expanded = '-', collapsed = '+', current_frame = '>' },
  render = { max_value_lines = 2 } })
function AdapterTestHelpTags()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/doc', 'p')
  local source = vim.env.NVIM_ZH_TEST_NVIM_DAP_UI .. '/doc/nvim-dap-ui.txt'
  assert(vim.uv.fs_copyfile(source, root .. '/doc/nvim-dap-ui.txt'))
  vim.cmd.helptags(root .. '/doc')
  vim.opt.rtp:append(root)
  require('nvim-zh').refresh()
end
require('nvim-zh').refresh()
function FixturePrintMapping()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if map.lhs == '<CR>' and map.desc and (map.desc == 'expand' or map.desc == '展开') then
        print('ACTION=' .. map.desc)
        return
      end
    end
  end
end
""")
