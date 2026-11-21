local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_MINI
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('mini', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local statusline = require('mini.statusline')
local surround = require('mini.surround')
local ai = require('mini.ai')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })

statusline.setup({})
surround.setup({})
ai.setup({})

local info = zh.status().adapters.mini
check(info and info.active, 'mini adapter should be active on fixed upstream')

vim.o.columns = 200
local mode, hl = statusline.section_mode({ trunc_width = 80 })
equal(mode, '普通', 'real MiniStatusline.section_mode Normal translated')
equal(hl, 'MiniStatuslineModeNormal', 'real MiniStatusline.section_mode highlight preserved')

local last_prompt = nil
local orig_input = vim.fn.input
vim.fn.input = function(opts)
  last_prompt = type(opts) == 'table' and opts.prompt or opts
  return 'my_fn'
end
local res = surround.user_input('Function name')
vim.fn.input = orig_input
equal(res, 'my_fn', 'user_input result preserved')
equal(last_prompt, '(mini.surround) 函数名: ', 'real MiniSurround.user_input prompt translated')

require('nvim-zh.plugins').teardown()
print('MINI_UPSTREAM_SPEC=PASS')
