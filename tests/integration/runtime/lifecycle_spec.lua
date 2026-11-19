local zh = require('nvim-zh')
local paths = require('nvim-zh.paths')
local fs = require('nvim-zh.fs')
local diagnostics = require('nvim-zh.diagnostics')
local original = diagnostics.setup
local function fail_once()
  diagnostics.setup = function(...)
    diagnostics.setup = original
    error('injected adapter setup failure')
  end
end
fail_once()
zh.setup({ modules = { core = { enabled = false } } })
assert(not zh.status().configured, 'first failed setup marked configured')
assert(not zh.status().ui.notify.active, 'first failed setup retained wrapper')
zh.setup({ modules = { core = { enabled = false } } })
assert(zh.status().configured and zh.status().runtime.status == 'ok')
local previous = zh.status().config
fs.write(paths.config(), vim.json.encode({ schema = 1, modules = { ui = { notify = false } },
  overrides = { ['nvim-ui'] = { [''] = { ['No information available'] = '不得部分生效' } } } }))
fail_once()
local result
zh.refresh(function(value) result = value end)
assert(result and not result.ok, 'adapter failure was not reported')
assert(vim.deep_equal(previous, zh.status().config), 'partial configuration survived rollback')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '没有可用的信息')
fs.write(paths.config(), '{bad json')
zh.refresh(function(value) result = value end)
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '没有可用的信息',
  'failed apply became last-good configuration')
vim.uv.fs_unlink(paths.config())
zh.refresh()
local previous_bundle = zh.status().version.active_bundle
local native_backend = require('nvim-zh.native_backend')
local original_start = native_backend.start
native_backend.start = function() error('injected native start failure') end
zh.refresh(function(value) result = value end)
native_backend.start = original_start
assert(result and not result.ok and result.error_code == 'native_failed', 'native start failure was not reported')
assert(zh.status().version.active_bundle == previous_bundle, 'native start failure published candidate resources')
assert(vim.deep_equal(previous, zh.status().config), 'native start failure leaked candidate configuration')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '没有可用的信息',
  'native start failure leaked candidate catalog')

local pending_native
native_backend.start = function(_, _, callback) pending_native = callback end
local cancelled
zh.refresh(function(value) cancelled = value end)
local cancelled_check
zh.check(function(value) cancelled_check = value end)
zh.teardown()
native_backend.start = original_start
assert(cancelled and not cancelled.ok and cancelled.status == 'cancelled' and cancelled.error_code == 'stopped',
  'pending refresh was not cancelled by teardown')
assert(type(cancelled.error) == 'string' and type(cancelled.task_id) == 'number'
  and type(cancelled.restart_required) == 'boolean', 'cancelled refresh contract incomplete')
assert(cancelled_check and not cancelled_check.ok and cancelled_check.status == 'cancelled'
  and cancelled_check.error_code == 'stopped', 'pending check was not cancelled by teardown')
if pending_native then pending_native() end
assert(not zh.status().configured and not zh.status().ui.notify.active)
local after_stop
zh.refresh(function(value) after_stop = value end)
assert(after_stop and after_stop.status == 'cancelled' and after_stop.error_code == 'stopped',
  'refresh after teardown was not rejected')
assert(after_stop.error and type(after_stop.restart_required) == 'boolean', 'stopped callback contract incomplete')
local stopped = zh.status().runtime
assert(stopped.status == 'disabled' and stopped.error == nil, 'successful teardown reported a runtime error')
zh.setup({ modules = { core = { enabled = false } } })
assert(zh.status().runtime.status == 'ok', 'stopped runtime could not restart')
assert(#vim.api.nvim_get_autocmds({ group = 'NvimZhRuntime', event = 'BufWritePost' }) == 1)
print('RUNTIME_LIFECYCLE_SPEC=PASS first_failure_cleanup partial_apply_rollback native_start_rollback last_good teardown_cancel restart idempotent_hooks')
