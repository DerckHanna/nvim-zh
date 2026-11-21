local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_GITSIGNS
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('gitsigns', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = true, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

local popup = require('gitsigns.popup')
local message = require('gitsigns.message')
local actions = require('gitsigns.actions')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })

local info = zh.status().adapters.gitsigns
check(info and info.active, 'gitsigns adapter should be active on fixed upstream')

message.error('%s is not a valid function or action', 'invalid_cmd')
check(vim.wait(2000, function() return #notifications >= 1 end), 'gitsigns notification delivered')
equal(notifications[1].msg, 'invalid_cmd 不是有效的函数或动作', 'real gitsigns.message.error translated')
equal(notifications[1].opts.title, 'gitsigns', 'gitsigns notification title preserved')

local winid, bufnr = popup.create({
  { { 'Hunk 2 of 5', 'Title' } },
  { { 'File added in commit', 'Title' } },
}, { relative = 'editor', row = 1, col = 1, width = 30, height = 4 }, 'test_hunk')
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
equal(lines[1], '第 2 / 5 个 Hunk', 'real popup.create Hunk header translated')
equal(lines[2], '在此提交中新增的文件', 'real popup.create File added header translated')
pcall(vim.api.nvim_win_close, winid, true)

require('nvim-zh.plugins').teardown()
print('GITSIGNS_UPSTREAM_SPEC=PASS')
