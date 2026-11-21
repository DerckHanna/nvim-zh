local M = {}
local paths = require('nvim-zh.paths')
local resources = require('nvim-zh.resources')
local config_file = require('nvim-zh.config_file')
local native_backend = require('nvim-zh.native_backend')
local state = { status = 'idle', generation = 0 }
local base, session, group, timer, busy, queued, stopped
local fingerprints, callbacks, observed = {}, {}, nil
local task, operation = 0, 0
local notices, adapter_signature = {}, nil

function M.changed(reason)
  state.generation = state.generation + 1
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'NvimZhChanged', modeline = false,
    data = { schema = 1, generation = state.generation, reason = reason } })
end

local function notify_error(message)
  if notices[message] then return end
  notices[message] = true
  vim.schedule(function()
    if not stopped and notices[message] then vim.notify('nvim-zh：' .. message, vim.log.levels.WARN) end
  end)
end

local function restart_required()
  local restart = resources.info().restart_required
  state.restart_required = restart
  if restart then notify_error('插件实现已更新，重启 Neovim 后自动生效。') end
  return restart
end

local function cancel(pending, restart)
  for _, cb in ipairs(pending) do
    pcall(cb.fn, { ok = false, status = 'cancelled', error_code = 'stopped', error = '同步已取消',
      restart_required = restart, task_id = cb.id })
  end
end

local function finish(result)
  if result.restart_required == nil then result.restart_required = restart_required() end
  busy = false
  state.status, state.error = result.status, result.error
  fingerprints = observed or { config_file.fingerprint(), resources.fingerprint() }
  observed = nil
  if result.error then notify_error(result.error) end
  if queued then
    queued = false
    M.refresh()
    return
  end
  local pending = callbacks
  callbacks = {}
  M.changed('refresh')
  for _, cb in ipairs(pending) do
    local value = vim.tbl_extend('force', vim.deepcopy(result), { task_id = cb.id })
    local ok, why = pcall(cb.fn, value)
    if not ok then notify_error('同步回调出错：' .. tostring(why)) end
  end
end

function M.refresh(callback)
  assert(callback == nil or type(callback) == 'function', 'refresh callback must be function')
  task = task + 1
  local id = task
  if stopped then
    if callback then cancel({ { id = id, fn = callback } }, state.restart_required or false) end
    return id
  end
  if callback then callbacks[#callbacks + 1] = { fn = callback, id = id } end
  if busy then queued = true; return id end
  if not session then
    finish({ ok = false, status = 'error', error_code = 'not_configured', error = '尚未执行 setup()' })
    return id
  end

  if timer then timer:stop() end
  busy = true
  notices = {}
  operation = operation + 1
  local token = operation
  local function current() return not stopped and token == operation end
  state.status = 'syncing'
  observed = { config_file.fingerprint(), resources.fingerprint() }
  local catalog = require('nvim-zh.catalog')
  local function fail(code, reason)
    if not current() then return end
    if not resources.active() then catalog.use_sources(false) end
    config_file.reject(reason)
    finish({ ok = false, status = 'error', error_code = code, error = tostring(reason) })
  end
  local effective, config_error = config_file.resolve(base)
  if not effective then fail('validation_failed', config_error); return id end

  local packs = require('nvim-zh.packs')
  local read, registrations = pcall(packs.read)
  if not read then fail('validation_failed', registrations); return id end
  local previous_info = session.snapshot()
  local previous_config = previous_info.config
  local previous_records = packs.snapshot()
  local previous_native = native_backend.info()
  local previous = resources.active()
  local prepared, candidate, deferred = pcall(function()
    resources.freeze()
    return resources.prepare()
  end)
  local resource_error
  if not prepared then
    resource_error = tostring(candidate)
    candidate = not previous and resources.recover() or nil
    if not candidate then fail('validation_failed', resource_error); return id end
  elseif deferred == 'adapter_restart' then
    candidate = previous or resources.recover()
    if not candidate then fail('validation_failed', '资源需要重启后应用'); return id end
  end

  local help = require('nvim-zh.help')
  local applied, completed = false, false
  local function rollback(code, reason, restore_native)
    if not current() then return end
    if applied then
      catalog.use_sources(previous and previous.sources or false)
      help.set_resource_root(previous and previous.root .. '/help' or nil)
      local restored, why = pcall(session.restore, previous_config, previous_info.configured, previous_records)
      adapter_signature = require('nvim-zh.plugins').loaded_signature()
      if not restored then reason = tostring(reason) .. '；恢复配置失败：' .. tostring(why) end
    end
    local function restored(native_error)
      if native_error then reason = tostring(reason) .. '；恢复原生状态失败：' .. tostring(native_error) end
      fail(code, reason)
    end
    local native = native_backend.info()
    if not restore_native or native.status == 'restore_failed' or native.reason == 'external_override' then
      restored()
    elseif previous_native.active and previous and (not native.active or native.mo_path ~= previous_native.mo_path) then
      local ok, why = pcall(native_backend.start, previous_config.modules.core, previous, restored)
      if not ok then restored(why) end
    elseif not previous_native.active and (native.active or native.status == 'preparing') then
      local ok, success, why = pcall(native_backend.stop)
      restored(not ok and success or not success and why or nil)
    else
      restored()
    end
  end

  local function complete(native_failure)
    if completed or not current() then return end
    completed = true
    local native = native_backend.info()
    if native_failure or native.status == 'restore_failed' then
      rollback('restore_failed', native_failure or native.reason or '原生语言恢复失败', false)
      return
    end
    if previous and candidate.manifest.bundle.id ~= previous.manifest.bundle.id
      and native.active and native.status == 'degraded' then
      rollback('validation_failed', native.reason or '原生资源应用失败，已保留上一份资源集', true)
      return
    end
    local latest, live_records = pcall(packs.read)
    if not latest then rollback('validation_failed', live_records, true); return end
    if queued or not vim.deep_equal(registrations, live_records)
      or observed[1] ~= config_file.fingerprint() or observed[2] ~= resources.fingerprint() then
      queued = true
      rollback('validation_failed', '准备期间同步输入已变更', true)
      return
    end
    local ok, err = pcall(function()
      applied = true
      catalog.use_sources(candidate.sources)
      help.set_resource_root(candidate.root .. '/help')
      catalog.reload()
      session.apply(effective, registrations)
      adapter_signature = require('nvim-zh.plugins').loaded_signature()
    end)
    if not current() then return end
    if not ok then rollback('apply_failed', err, true); return end
    local committed, commit_error = pcall(resources.commit, candidate)
    if not committed then rollback('commit_failed', commit_error, true); return end
    session.commit(effective)
    config_file.commit()
    local degraded = native.status == 'degraded' or native.status == 'unsupported'
    if degraded then notify_error('原生汉化未完全生效，可用 :NvimZh 查看具体原因。') end
    finish({ ok = not resource_error, status = resource_error and 'error' or degraded and 'degraded' or 'ok',
      error = resource_error, error_code = resource_error and 'validation_failed' or nil })
  end

  local started, failure = pcall(native_backend.start, effective.modules.core, candidate, complete)
  if not started then
    if completed then
      notify_error('原生启动在完成回调后抛错：' .. tostring(failure))
    else
      completed = true
      rollback('native_failed', failure, true)
    end
  end
  return id
end

function M.request(reason)
  if stopped or not session then return end
  if busy then queued = true; return end
  local token = operation
  if timer then timer:stop() else timer = vim.uv.new_timer() end
  timer:start(reason == 'pack' and 0 or 180, 0, vim.schedule_wrap(function()
    if not stopped and token == operation then M.refresh() end
  end))
end

function M.setup(opts, injected_session)
  base, session, stopped = vim.deepcopy(opts), injected_session, false
  assert(type(session) == 'table' and type(session.apply) == 'function' and type(session.restore) == 'function',
    'runtime session must provide apply/restore')
  if not group then
    group = vim.api.nvim_create_augroup('NvimZhRuntime', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(event)
      local path = vim.fn.fnamemodify(event.file, ':p')
      path = vim.uv.fs_realpath(path) or path
      if vim.fs.normalize(path) == vim.fs.normalize(paths.config()) then M.request('config') end
    end })
    vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, { group = group, callback = function()
      if config_file.fingerprint() ~= fingerprints[1] or resources.fingerprint() ~= fingerprints[2] then M.request('external') end
      local plugins = require('nvim-zh.plugins')
      if not busy and session and adapter_signature ~= plugins.loaded_signature() then
        plugins.setup(session.snapshot().config.modules.plugins)
        adapter_signature = plugins.loaded_signature()
        M.changed('adapters')
      end
    end })
    vim.api.nvim_create_autocmd('FocusGained', { group = group, callback = function()
      if not busy then
        local packs = require('nvim-zh.packs')
        local before = packs.info()
        packs.sync()
        if not vim.deep_equal(before, packs.info()) then M.changed('packs') end
      end
    end })
    vim.api.nvim_create_autocmd('PackChanged', { group = group, callback = function(event)
      local data = event.data or {}
      local path = data.path and (vim.uv.fs_realpath(data.path) or data.path)
      if path == paths.root and (data.kind == 'update' or data.kind == 'install') then
        M.request('pack')
      elseif require('nvim-zh.plugins').package_changed(data) then
        M.changed('adapters')
      end
    end })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function() M.stop() end })
  end
  return M.refresh()
end

function M.info()
  return vim.tbl_extend('force', vim.deepcopy(state), { config_file = config_file.info() })
end

function M.stop(cleanup)
  stopped = true
  operation = operation + 1
  busy, queued, observed = false, false, nil
  local pending, restart = callbacks, state.restart_required or false
  callbacks = {}
  if timer then timer:stop(); timer:close(); timer = nil end
  if group then pcall(vim.api.nvim_del_augroup_by_id, group); group = nil end
  local ok, err = native_backend.stop()
  local restored, why = true, nil
  if cleanup then restored, why = pcall(cleanup) end
  local packs = package.loaded['nvim-zh.packs']
  if packs then packs.stop() end
  state.status = ok and restored and 'disabled' or 'restore_failed'
  state.error = not ok and tostring(err) or not restored and tostring(why) or nil
  M.changed('stop')
  cancel(pending, restart)
  if not ok then return nil, err end
  if not restored then return nil, why end
  return true
end
return M
