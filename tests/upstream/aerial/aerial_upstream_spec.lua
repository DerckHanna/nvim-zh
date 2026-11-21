local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_AERIAL
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('aerial', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local aerial = require('aerial')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })
aerial.setup({ backends = { 'lsp', 'markdown' } })

local info = zh.status().adapters.aerial
check(info and info.active, 'aerial adapter should be active on fixed upstream')

local printed = {}
local orig_print = _G.print
_G.print = function(s) printed[#printed + 1] = tostring(s) end
require('aerial.command').info()
_G.print = orig_print

equal(printed[1], 'Aerial 信息', 'real AerialInfo header translated')
equal(printed[4], '已配置的后端：', 'real AerialInfo Configured backends translated')
check(printed[5]:find('lsp (不支持) [未找到支持符号的 LSP 客户端]', 1, true) ~= nil,
  'real AerialInfo lsp backend line translated')

vim.cmd('enew')
vim.bo.filetype = 'text'
aerial.open({ focus = true })
local aer_buf = vim.api.nvim_get_current_buf()
check(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(aer_buf, 0, -1, false), '\n')
  return text:find('暂无符号', 1, true) ~= nil
end, 20), 'real aerial outline buffer No symbols translated')

local keymap_util = require('aerial.keymap_util')
local config = require('aerial.config')
keymap_util.show_help('aerial.actions', config.keymaps)
local help_buf = vim.api.nvim_get_current_buf()
local help_text = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), '\n')
check(help_text:find('显示默认键映射', 1, true) ~= nil, 'real aerial help float translated')
check(help_text:find('关闭 Aerial Window', 1, true) ~= nil, 'real aerial help close action translated')
vim.cmd.close()
aerial.close()

require('nvim-zh.plugins').teardown()
print('AERIAL_UPSTREAM_SPEC=PASS')
