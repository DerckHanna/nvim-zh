local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase3/helpers.lua')
local check, equal = h.check, h.equal

local baseline_calls = {}
local baseline = function(msg) table.insert(baseline_calls, msg) return 'baseline' end
vim.notify = baseline
local baseline_once = vim.notify_once
local before = { vim.notify, vim.notify_once, vim.ui.input, vim.ui.select, vim.api.nvim_echo }
local ok = pcall(require('nvim-zh').setup, { modules = { ui = { notify = 'invalid' } } })
check(not ok, 'invalid UI config was accepted')
check(vim.notify == before[1] and vim.notify_once == before[2], 'invalid config changed notify wrappers')
check(vim.ui.input == before[3] and vim.ui.select == before[4] and vim.api.nvim_echo == before[5], 'invalid config changed other wrappers')

-- nvim-zh loads after an external provider: teardown returns to that provider.
local external_before_calls = 0
local external_before = function(msg, level, opts)
  external_before_calls = external_before_calls + 1
  return baseline(msg, level, opts)
end
vim.notify = external_before
h.setup({ notify = true, prompts = false, echo = false })
local ours = vim.notify
check(ours ~= external_before, 'external provider was not wrapped')
vim.notify('Ready')
equal(baseline_calls[#baseline_calls], '就绪', 'external-before translation')
equal(external_before_calls, 1, 'external-before call count')
local old_wrapper = ours
require('nvim-zh').reload()
check(vim.notify ~= old_wrapper and vim.notify ~= external_before, 'reload did not safely rebuild owned wrapper')
vim.notify('Ready')
equal(external_before_calls, 2, 'reload duplicated external-before wrapper')
equal(baseline_calls[#baseline_calls], '就绪', 'reload translation')
local info = require('nvim-zh').info().ui
check(info.notify.active == true and info.notify_once.active == true, 'active UI status absent')
h.setup({ notify = false, prompts = false, echo = false })
check(vim.notify == external_before and vim.notify_once == baseline_once, 'teardown did not restore external provider')
vim.notify('Ready')
equal(baseline_calls[#baseline_calls], 'Ready', 'disabled adapter still translated')
vim.notify = baseline

-- An external replacement after nvim-zh owns the chain; reload must not steal it.
h.setup({ notify = true, prompts = false, echo = false })
ours = vim.notify
local external_after_calls = 0
local external_after = function(msg, level, opts)
  external_after_calls = external_after_calls + 1
  return ours(msg, level, opts)
end
vim.notify = external_after
vim.notify('Ready')
equal(baseline_calls[#baseline_calls], '就绪', 'external-after initial translation')
local before_reload = vim.notify
require('nvim-zh').reload()
check(vim.notify == before_reload, 'reload stole external replacement')
vim.notify('Ready')
equal(external_after_calls, 2, 'external-after call count')
equal(baseline_calls[#baseline_calls], '就绪', 'external-after reload translation')
info = require('nvim-zh').info().ui
check(info.notify.active == false and info.notify.reason == 'external_override', 'external override degradation not reported')
local degraded_health = require('nvim-zh.health').collect()
local health_reason = false
for _, result in ipairs(degraded_health) do
  if result.name == 'ui.notify' and result.status == 'warn' and result.message:find('external_override', 1, true) then
    health_reason = true
  end
end
check(health_reason, 'health omitted external override reason')
require('nvim-zh.ui').teardown()
check(vim.notify == external_after, 'teardown overwrote external replacement')
check(require('nvim-zh').info().ui.notify.enabled == false, 'direct teardown did not disable adapter state')
vim.notify('Ready')
equal(baseline_calls[#baseline_calls], 'Ready', 'disabled wrapper retained by external provider still translated')
vim.notify = baseline

-- Catalog/override reload runs before adapter reconstruction.
h.setup({ notify = true, prompts = false, echo = false })
local engine = require('nvim-zh.engine')
local ui = require('nvim-zh.ui')
local original_engine_reload, original_ui_reload = engine.reload, ui.reload
local order = {}
engine.reload = function()
  table.insert(order, 'catalogs')
  return original_engine_reload()
end
ui.reload = function(...)
  table.insert(order, 'adapters')
  return original_ui_reload(...)
end
require('nvim-zh').reload()
engine.reload, ui.reload = original_engine_reload, original_ui_reload
equal(table.concat(order, ','), 'catalogs,adapters', 'reload order')

local health = require('nvim-zh.health').collect()
local found_ui = false
for _, result in ipairs(health) do
  if result.name == 'ui.notify' then found_ui = true end
end
check(found_ui, 'health did not report UI adapter')

print('UI_LIFECYCLE_SPEC=PASS external_before=' .. external_before_calls .. ' external_after=' .. external_after_calls)
