local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_CONFORM
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('conform', upstream)
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

local conform = require('conform')
local health = require('conform.health')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })

local info = zh.status().adapters.conform
check(info and info.active, 'conform adapter should be active on fixed upstream')

conform.setup({
  formatters_by_ft = {
    lua = { 'nonexistent_test_formatter' },
  },
  formatters = {
    nonexistent_test_formatter = {
      command = 'nonexistent_test_formatter_bin_xyz',
    },
  },
})

conform.resolve_formatters({ 'nonexistent_test_formatter' }, 0, true, false)
check(vim.wait(2000, function() return #notifications >= 1 end), 'resolve_formatters notification delivered')
equal(notifications[1].msg,
  "格式化器 'nonexistent_test_formatter' 不可用：未找到命令 'nonexistent_test_formatter_bin_xyz'",
  'real resolve_formatters notification translation')

health.show_window()
local buf = vim.api.nvim_get_current_buf()
equal(vim.bo[buf].filetype, 'conform-info', 'ConformInfo window opened')
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
check(text:find('日志文件：', 1, true) ~= nil, 'ConformInfo log file translated')
check(text:find('当前 Buffer 的格式化器：', 1, true) ~= nil, 'ConformInfo buffer header translated')
check(text:find('其他格式化器：', 1, true) ~= nil, 'ConformInfo other header translated')
check(text:find("nonexistent_test_formatter 不可用：未找到命令 'nonexistent_test_formatter_bin_xyz'", 1, true) ~= nil,
  'ConformInfo unavailable formatter line translated')
vim.cmd.close()

require('nvim-zh.plugins').teardown()
print('CONFORM_UPSTREAM_SPEC=PASS')
