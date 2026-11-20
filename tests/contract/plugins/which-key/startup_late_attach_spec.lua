-- Regression for BUG-01: a supported plugin that finishes loading AFTER
-- nvim-zh setup, without emitting User LazyLoad and without any FocusGained /
-- BufEnter boundary, must still get its display formatter attached.
--
-- Real-world trigger: which-key's plugin/which-key.lua auto-setups on a 500ms
-- timer. Before the fix the adapter stayed not_loaded/not_initialized and the
-- popup showed English until a focus event happened to fire. The bounded
-- startup sweep in plugins.lua re-attaches once the module signature changes.
--
-- This drives the real adapter + engine + catalog path and observes the actual
-- replace.desc output a user would see; it does not copy the sweep logic.
local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal

-- Start with which-key absent, exactly like init.lua running before the plugin
-- directory is sourced.
package.loaded['which-key'] = nil
package.loaded['which-key.config'] = nil
package.loaded['which-key.view'] = nil

local overrides = h.overrides()
overrides['which-key'].desc['Prev end of word'] = '上一个词尾'
overrides['which-key'].desc['First line'] = '第一行'
h.setup({ auto = true, lazy_load = true, disabled = {} }, overrides)

local adapter = require('nvim-zh.adapters.which_key')
equal(require('nvim-zh').status().adapters['which-key'].active, false,
  'adapter should be inactive before the plugin loads')

-- The plugin now loads and auto-setups (its 500ms timer equivalent). No
-- LazyLoad event, no FocusGained, no BufEnter, no manual refresh.
local config = { replace = { desc = {
  { '<Plug>%(?(.*)%)?', '%1' },
  { '^%+', '' },
} } }
local view = {}
function view.replace(field, value)
  for _, repl in pairs(config.replace[field]) do
    value = type(repl) == 'function' and (repl(value) or value) or value:gsub(repl[1], repl[2])
  end
  return value
end
local which_key = { did_setup = false }
function which_key.setup()
  which_key.did_setup = true
  config.replace.desc = { { '<Plug>%(?(.*)%)?', '%1' }, { '^%+', '' } }
end
package.loaded['which-key.config'] = config
package.loaded['which-key.view'] = view
package.loaded['which-key'] = which_key
which_key.setup()

-- Wait past the last startup sweep delay (1600ms) without any UI boundary.
local attached = vim.wait(3000, function()
  return require('nvim-zh').status().adapters['which-key'].active == true
end, 50)
check(attached, 'startup sweep did not attach late-loading which-key without a focus event')

-- User-observable result: the real replace.desc chain now yields Chinese.
equal(view.replace('desc', 'Prev end of word'), '上一个词尾',
  'late-loaded which-key description not translated (BUG-01 regression)')
equal(view.replace('desc', 'First line'), '第一行',
  'second late-loaded description not translated')

-- Idempotency: repeated public setup must not stack formatters.
which_key.setup()
which_key.setup()
local count = 0
for _, repl in ipairs(config.replace.desc) do
  if type(repl) == 'function' then count = count + 1 end
end
equal(count, 1, 'repeated setup stacked which-key formatters')

-- The startup sweep must not reclaim an external replacement.
local external = { function(value) return 'External ' .. value end }
config.replace.desc = external
require('nvim-zh').refresh()
vim.wait(200, function() return false end, 20)
equal(#external, 1, 'startup sweep reclaimed external which-key replacement')
equal(require('nvim-zh').status().adapters['which-key'].reason, 'external_override',
  'external replacement not reported after sweep')

-- teardown clears the startup timers and detaches; no residual owned formatter.
require('nvim-zh').teardown()
check(require('nvim-zh').status().adapters['which-key'] == nil, 'teardown retained the package adapter')

print('STARTUP_LATE_ATTACH_SPEC=PASS late_auto_setup=no_focus_boundary idempotent external_override=safe teardown=clean')
