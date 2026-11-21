local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_BLINK_CMP
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('blink-cmp', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = true, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local echoed = {}
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, opts)
  local parts = {}
  for _, c in ipairs(chunks or {}) do
    parts[#parts + 1] = c[1] or ''
  end
  echoed[#echoed + 1] = table.concat(parts)
  return orig_echo(chunks, history, opts)
end

local utils = require('blink.cmp.lib.utils')
local build = require('blink.cmp.fuzzy.build')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })

local info = zh.status().adapters['blink-cmp']
check(info and info.active, 'blink-cmp adapter should be active on fixed upstream')

vim.api.nvim_exec_autocmds('UIEnter', {})
build.build_log()
check(vim.wait(2000, function() return #echoed >= 1 end), 'blink.cmp build_log echo delivered')
check(echoed[#echoed]:find('没有可用的构建日志', 1, true) ~= nil, 'real build_log notification translated')

vim.api.nvim_echo = orig_echo
require('nvim-zh.plugins').teardown()
print('BLINK_CMP_UPSTREAM_SPEC=PASS')
