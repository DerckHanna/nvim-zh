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

fs.write(paths.config(), '{"schema":1,"modules":{"ui":{"notify":false}}}')
native_backend.start = function(_, _, done) done('injected native restore failure') end
zh.refresh(function(value) result = value end)
native_backend.start = original_start
assert(result.error_code == 'restore_failed' and zh.status().config.modules.ui.notify and zh.status().ui.notify.active,
  'native callback failure committed the candidate')
assert(zh.status().version.active_bundle == previous_bundle)

local store = require('nvim-zh.pack_store')
local original_records = store.records
store.records = function() error('injected registration read failure') end
zh.refresh(function(value) result = value end)
store.records = original_records
assert(result.error_code == 'validation_failed' and zh.status().config.modules.ui.notify,
  'registration read failure committed the candidate')

local resources = require('nvim-zh.resources')
local original_commit = resources.commit
resources.commit = function() error('injected persistence failure') end
zh.refresh(function(value) result = value end)
resources.commit = original_commit
assert(result.error_code == 'commit_failed' and zh.status().config.modules.ui.notify and zh.status().ui.notify.active,
  'persistence failure leaked a candidate display wrapper')
assert(zh.status().version.active_bundle == previous_bundle)
vim.uv.fs_unlink(paths.config())

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
local delayed
native_backend.start = function(_, _, callback) delayed = callback end
local counts, results = {}, {}
local function record(value)
  counts[value.task_id] = (counts[value.task_id] or 0) + 1
  results[value.task_id] = value.status
end
local old = zh.refresh(function(value)
  record(value)
  native_backend.start = original_start
  zh.setup({ modules = { core = { enabled = false } } })
end)
local before, nested, latest
before = zh.check(function(value)
  record(value)
  nested = zh.check(record)
end)
latest = zh.check(record)
assert(vim.wait(1000, function() return counts[nested] ~= nil end))
assert(results[before] == 'cancelled' and results[latest] == 'cancelled' and results[nested] ~= 'cancelled')
local stopped_check, restarted_check
stopped_check = zh.check(function(value)
  record(value)
  restarted_check = zh.check(record)
end)
assert(zh.teardown())
assert(results[old] == 'cancelled' and zh.status().configured)
assert(#vim.api.nvim_get_autocmds({ group = 'NvimZhRuntime', event = 'BufWritePost' }) == 1)
delayed()
assert(vim.wait(1000, function() return counts[restarted_check] ~= nil end))
for _, id in ipairs({ old, before, nested, latest, stopped_check, restarted_check }) do assert(counts[id] == 1) end
assert(results[stopped_check] == 'cancelled' and results[restarted_check] ~= 'cancelled')
local generations, nested_refresh = {}, nil
local hook = vim.api.nvim_create_autocmd('User', { pattern = 'NvimZhChanged', callback = function(event)
  local data = event.data
  assert(data.schema == 1 and type(data.generation) == 'number' and type(data.reason) == 'string')
  generations[#generations + 1] = data.generation
  if #generations == 1 then nested_refresh = zh.refresh(record) end
end })
local request = zh.refresh(record)
assert(counts[request] == 1 and counts[nested_refresh] == 1, 'event reentry lost pending callback')
assert(#generations >= 1 and (#generations == 1 or generations[2] > generations[1]))
vim.api.nvim_del_autocmd(hook)
local old_pending, first_result, final_result
native_backend.start = function(_, _, done) old_pending = done end
fs.write(paths.config(), '{"schema":1,"modules":{"ui":{"notify":false}}}')
zh.refresh(function(value) first_result = value end)
fs.write(paths.config(), '{"schema":1,"modules":{"ui":{"notify":true}}}')
zh.refresh(function(value) final_result = value end)
assert(not first_result and not final_result)
native_backend.start = original_start
old_pending()
assert(first_result.ok and final_result.ok and first_result.task_id ~= final_result.task_id)
assert(zh.status().config.modules.ui.notify and zh.status().ui.notify.active)
vim.uv.fs_unlink(paths.config())
print('RUNTIME_LIFECYCLE_SPEC=PASS first_failure_cleanup partial_apply_rollback native_start_rollback last_good teardown_cancel restart idempotent_hooks')
