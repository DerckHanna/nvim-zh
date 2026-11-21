local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_SNACKS
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('snacks', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local snacks = require('snacks')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })
snacks.setup({
  dashboard = { enabled = true },
  picker = { enabled = true },
  input = { enabled = true },
  notifier = { enabled = false },
})

local info = zh.status().adapters.snacks
check(info and info.active, 'snacks adapter should be active on fixed upstream')

-- Identity checks required by :checkhealth snacks
check(vim.ui.input == Snacks.input.input, 'vim.ui.input identity with Snacks.input.input must be preserved')
check(vim.ui.select == Snacks.picker.select, 'vim.ui.select identity with Snacks.picker.select must be preserved')

-- Dashboard preset keys translation
local dash = require('snacks.dashboard')
local keys = dash.sections.keys()({
  opts = {
    preset = {
      keys = {
        { icon = 'f', key = 'f', desc = 'Find File', action = ':qa' },
        { icon = 'q', key = 'q', desc = 'Quit', action = ':qa' },
      },
    },
  },
})
equal(keys[1].desc, '查找文件', 'real dashboard preset Find File translated')
equal(keys[2].desc, '退出', 'real dashboard preset Quit translated')

-- Picker auto-generated title translation via picker.new
local picker = Snacks.picker.pick({
  source = 'buffers',
  items = { { text = 'demo.lua' } },
  show_empty = true,
})
equal(picker.title, 'Buffer 列表', 'real picker title translated')
picker:close()

-- Snacks.notify translation
local notifications = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end
Snacks.notify.warn('No results found for `files`', { title = 'Snacks Picker' })
vim.notify = orig_notify
equal(notifications[#notifications].msg, '未找到 `files` 的结果', 'real Snacks.notify translated')

require('nvim-zh.plugins').teardown()
print('SNACKS_UPSTREAM_SPEC=PASS')
