local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local group = vim.api.nvim_create_augroup('NvimZhPluginLateLoadProbe', { clear = true })
vim.api.nvim_create_autocmd('User', { group = group, pattern = 'LazyLoad', callback = function() end })
local function autocmds()
  local ok, result = pcall(vim.api.nvim_get_autocmds, { group = 'NvimZhPluginLateLoad', event = 'User', pattern = 'LazyLoad' })
  return ok and result or {}
end
package.loaded['which-key.config'] = nil
package.loaded['which-key'] = nil
package.loaded['telescope.pickers'] = nil
h.setup({ auto = true, lazy_load = false, disabled = {} })
equal(#autocmds(), 0, 'disabled lazy integration created autocmd')
h.setup()
equal(#autocmds(), 1, 'lazy integration did not create exactly one autocmd')
h.setup()
equal(#autocmds(), 1, 'repeated setup duplicated lazy autocmd')
local wk = { replace = { desc = {} } }
package.loaded['which-key.config'] = wk
vim.api.nvim_exec_autocmds('User', { pattern = 'LazyLoad', data = 'which-key.nvim', modeline = false })
equal(#wk.replace.desc, 1, 'LazyLoad did not attach late which-key')
vim.api.nvim_exec_autocmds('User', { pattern = 'LazyLoad', data = 'which-key.nvim', modeline = false })
vim.api.nvim_exec_autocmds('User', { pattern = 'LazyLoad', data = 'which-key.nvim', modeline = false })
equal(#wk.replace.desc, 1, 'repeated LazyLoad duplicated which-key formatter')

-- A normal public which-key setup may rebuild replace.desc; attach after it returns.
local which_key = {}
which_key.setup = function()
  wk.replace.desc = { function(value) return value end }
end
package.loaded['which-key'] = which_key
local wrapped_setup = which_key.setup
require('nvim-zh').refresh()
check(which_key.setup ~= wrapped_setup, 'which-key public setup was not chained')
which_key.setup()
equal(#wk.replace.desc, 2, 'normal which-key setup did not regain owned formatter')

-- Direct external replacement is indistinguishable from an intentional override: never reclaim.
local external = { function(value) return 'External ' .. value end }
wk.replace.desc = external
require('nvim-zh').refresh()
equal(#external, 1, 'refresh reclaimed external which-key replacement')
equal(require('nvim-zh').status().plugins['which-key'].reason, 'external_override', 'external replacement not reported')

h.setup({ auto = true, lazy_load = false, disabled = {} })
equal(#autocmds(), 0, 'disabling lazy integration did not clear autocmd')
require('nvim-zh.plugins').teardown()
equal(#autocmds(), 0, 'teardown left lazy autocmd')
check(which_key.setup == wrapped_setup, 'teardown did not restore which-key setup')
print('LAZY_LATE_LOAD_SPEC=PASS autocmd=idempotent external_override=safe')
