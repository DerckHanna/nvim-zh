local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal

local baseline_calls = {}
local baseline = function(opts, defaults)
  table.insert(baseline_calls, { opts = opts, defaults = defaults })
  return opts
end
local pickers = { new = baseline }
package.loaded['telescope.pickers'] = pickers
local wk_config = { replace = { desc = {} } }
package.loaded['which-key.config'] = wk_config
local before_desc = #wk_config.replace.desc
local ok = pcall(require('nvim-zh').setup, { modules = { plugins = { auto = 'invalid' } } })
check(not ok, 'invalid plugins.auto accepted')
check(pickers.new == baseline and #wk_config.replace.desc == before_desc, 'invalid config caused plugin side effects')
ok = pcall(require('nvim-zh').setup, { modules = { plugins = { disabled = false } } })
check(not ok, 'invalid plugins.disabled accepted')
check(pickers.new == baseline and #wk_config.replace.desc == before_desc, 'invalid disabled config caused side effects')

h.setup({ auto = false, disabled = {} })
check(pickers.new == baseline and #wk_config.replace.desc == 0, 'plugins.auto=false attached adapters')
h.setup()
check(pickers.new ~= baseline and #wk_config.replace.desc == 1, 'auto adapters not attached')

-- External provider installed before nvim-zh remains in the chain and is restored.
local ours = pickers.new
local external_before_calls = 0
local external_before = function(opts, defaults)
  external_before_calls = external_before_calls + 1
  return ours(opts, defaults)
end
-- Rebuild with the external provider as the original by explicitly tearing down first.
require('nvim-zh.plugins').teardown()
pickers.new = baseline
local external_provider = function(opts, defaults)
  external_before_calls = external_before_calls + 1
  return baseline(opts, defaults)
end
pickers.new = external_provider
h.setup()
ours = pickers.new
pickers.new({ prompt_title = 'Find Files' }, {})
equal(baseline_calls[#baseline_calls].opts.prompt_title, 'Find Files', 'lifecycle hook mutated Telescope internal title')
equal(external_before_calls, 1, 'external-before call count')
h.setup({ auto = true, disabled = { 'telescope' } })
check(pickers.new == external_provider, 'teardown did not restore previous external provider')

-- External replacement after nvim-zh owns the chain; refresh must not reclaim it.
h.setup()
ours = pickers.new
local external_after_calls = 0
local external_after = function(opts, defaults)
  external_after_calls = external_after_calls + 1
  return ours(opts, defaults)
end
pickers.new = external_after
require('nvim-zh').refresh()
check(pickers.new == external_after, 'refresh reclaimed external Telescope replacement')
pickers.new({ prompt_title = 'Find Files' }, {})
equal(baseline_calls[#baseline_calls].opts.prompt_title, 'Find Files', 'external-after lifecycle hook mutated internal title')
local info = require('nvim-zh').status().plugins.telescope
check(not info.active and info.reason == 'external_override', 'Telescope external degradation missing')
require('nvim-zh.plugins').teardown()
check(pickers.new == external_after, 'teardown overwrote external Telescope replacement')
pickers.new({ prompt_title = 'Find Files' }, {})
equal(baseline_calls[#baseline_calls].opts.prompt_title, 'Find Files', 'stale Telescope wrapper remained active')

-- Replacing a list on the same module is an external override, not a module generation.
local current_config = package.loaded['which-key.config']
current_config.replace.desc = {}
h.setup()
local old_list = current_config.replace.desc
local new_list = { function(value) return 'External ' .. value end }
current_config.replace.desc = new_list
require('nvim-zh').refresh()
equal(#new_list, 1, 'reload appended into external which-key replacement list')
check(require('nvim-zh').status().plugins['which-key'].reason == 'external_override', 'which-key external override not reported')
require('nvim-zh.plugins').teardown()
equal(#old_list, 0, 'teardown did not remove owned which-key formatter from old list')
equal(#new_list, 1, 'teardown changed external which-key list')

local found = false
for _, result in ipairs(require('nvim-zh.health').collect()) do
  if result.name == 'plugins.telescope' then found = true end
end
check(found, 'health omitted plugin adapters')
print('PLUGIN_LIFECYCLE_SPEC=PASS loading_order=before,after no_reclaim=true')
