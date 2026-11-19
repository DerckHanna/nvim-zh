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

local function changed(reason)
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

local function finish(result)
  if result.restart_required == nil then result.restart_required = state.restart_required or false end
  busy = false
  state.status, state.error = result.status, result.error
  state.generation = state.generation + 1
  fingerprints = observed or { config_file.fingerprint(), resources.fingerprint() }
  observed = nil
  if result.error then notify_error(result.error) end
  if queued then
    queued = false
    changed('refresh')
    if not stopped then M.request('queued') end
    return
  end
  local pending = callbacks
  callbacks = {}
  changed('refresh')
  for _, cb in ipairs(pending) do
    local value
    if stopped then
      value = { ok = false, status = 'cancelled', error_code = 'stopped', error = '同步已取消',
        restart_required = state.restart_required or false, task_id = cb.id }
    else
      value = vim.tbl_extend('force', vim.deepcopy(result), { task_id = cb.id })
    end
    local ok, why = pcall(cb.fn, value)
    if not ok then notify_error('同步回调出错：' .. tostring(why)) end
  end
end

function M.refresh(callback)
  assert(callback == nil or type(callback) == 'function', 'refresh callback must be function')
  task = task + 1
  local id = task
  if stopped then
    if callback then pcall(callback, { ok = false, status = 'cancelled', error_code = 'stopped', error = '同步已取消',
      restart_required = state.restart_required or false, task_id = id }) end
    return id
  end
  if callback then callbacks[#callbacks + 1] = { fn = callback, id = id } end
  if busy then queued = true; return id end
  if not session then
    observed = nil
    finish({ ok = false, status = 'error', error_code = 'not_configured', error = '尚未执行 setup()' })
    return id
  end

  busy = true
  notices = {}
  operation = operation + 1
  local token = operation
  state.status = 'syncing'
  observed = { config_file.fingerprint(), resources.fingerprint() }
  local previous_info = session.snapshot()
  local previous_config = previous_info.config
  local previous_native = native_backend.info()
  local effective = config_file.resolve(base)
  local previous = resources.active()
  local prepared, candidate, deferred = pcall(function()
    resources.freeze()
    return resources.prepare()
  end)
  local resource_error
  if not prepared or deferred == 'adapter_restart' then
    if not prepared then resource_error = tostring(candidate) end
    candidate = previous or resources.recover()
  end

  local catalog = require('nvim-zh.catalog')
  -- Registered user loaders and builtins share the same refresh lifecycle. A
  -- later lookup reloads data without executing newly installed implementation.
  catalog.reload()
  local old_help = previous and previous.root .. '/help' or nil
  local completed = false

  local function rollback(reason, restore_native)
    config_file.reject(reason)
    catalog.use_sources(previous and previous.sources or false)
    require('nvim-zh.help').set_resource_root(old_help)
    local restored, why = pcall(session.restore, previous_config, previous_info.configured)
    adapter_signature = require('nvim-zh.plugins').loaded_signature()
    if restore_native then
      local ok, err = pcall(function()
        local current = native_backend.info()
        if previous_native.active and previous then
          if not current.active or current.mo_path ~= previous_native.mo_path then
            native_backend.start(previous_config.modules.core, previous, function() end)
          end
        elseif current.active or current.status == 'preparing' then
          native_backend.stop()
        end
      end)
      if not ok then restored, why = false, tostring(why or '') .. '；恢复原生状态失败：' .. tostring(err) end
      local native_state = native_backend.info()
      if native_state.status == 'restore_failed' then
        restored, why = false, tostring(why or '') .. '；' .. tostring(native_state.reason or '原生状态恢复失败')
      end
    end
    return restored, why
  end

  local ok, err = pcall(function()
    if candidate then
      catalog.use_sources(candidate.sources)
      require('nvim-zh.help').set_resource_root(candidate.root .. '/help')
    else
      catalog.use_sources(false)
    end
    session.apply(effective)
    adapter_signature = require('nvim-zh.plugins').loaded_signature()
  end)
  if not ok then
    local restored, why = rollback(err, false)
    finish({ ok = false, status = 'error', error_code = 'apply_failed', error = tostring(err)
      .. (restored and '' or '；恢复配置失败：' .. tostring(why)), restart_required = restart_required() })
    return id
  end

  local function complete(native_failure)
    if completed or stopped or token ~= operation then return end
    completed = true
    local native = native_backend.info()
    local publish = candidate
    local resource_failure
    if previous and candidate and previous.manifest.bundle.id ~= candidate.manifest.bundle.id
      and native.active and native.status == 'degraded' then
      publish = previous
      catalog.use_sources(previous.sources)
      require('nvim-zh.help').set_resource_root(previous.root .. '/help')
      resource_failure = native.reason or '原生资源应用失败，已保留上一份资源集'
    end

    local committed, commit_error = pcall(function()
      if publish then resources.commit(publish) end
      config_file.commit()
    end)
    if not committed then
      local restored, why = rollback(commit_error, true)
      finish({ ok = false, status = 'error', error_code = 'commit_failed', error = tostring(commit_error)
        .. (restored and '' or '；恢复失败：' .. tostring(why)), restart_required = restart_required() })
      return
    end

    local error = native_failure or resource_error or resource_failure or config_file.info().error
    if not error and native.status == 'restore_failed' then
      error = native.reason or '原生语言恢复失败'
    end
    local restart = restart_required()
    local degraded = native.status == 'degraded' or native.status == 'unsupported'
    if degraded then notify_error('原生汉化未完全生效，可用 :NvimZh 查看具体原因。') end
    finish({ ok = error == nil, status = error and 'error' or degraded and 'degraded' or 'ok',
      error = error, error_code = native_failure and 'restore_failed' or error and 'validation_failed' or nil,
      restart_required = restart })
  end

  if candidate then
    local started, failure = pcall(native_backend.start, effective.modules.core, candidate, complete)
    if not started then
      if completed then
        notify_error('原生启动在完成回调后抛错：' .. tostring(failure))
        return id
      end
      completed = true
      local restored, why = rollback(failure, true)
      finish({ ok = false, status = 'error', error_code = 'native_failed', error = tostring(failure)
        .. (restored and '' or '；恢复失败：' .. tostring(why)), restart_required = restart_required() })
    end
  else
    complete()
  end
  return id
end

function M.request(reason)
  if stopped or not session then return end
  if timer then timer:stop() else timer = vim.uv.new_timer() end
  timer:start(reason == 'pack' and 0 or 180, 0, vim.schedule_wrap(function()
    if not stopped then M.refresh() end
  end))
end

function M.setup(opts, injected_session)
  base, session, stopped = vim.deepcopy(opts), injected_session, false
  assert(type(session) == 'table' and type(session.apply) == 'function' and type(session.restore) == 'function',
    'runtime session must provide apply/restore')
  if not group then
    group = vim.api.nvim_create_augroup('NvimZhRuntime', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(event)
      if vim.fs.normalize(vim.fn.fnamemodify(event.file, ':p')) == vim.fs.normalize(paths.config()) then M.request('config') end
    end })
    vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, { group = group, callback = function()
      if config_file.fingerprint() ~= fingerprints[1] or resources.fingerprint() ~= fingerprints[2] then M.request('external') end
      local plugins = require('nvim-zh.plugins')
      if not busy and session and adapter_signature ~= plugins.loaded_signature() then
        plugins.setup(session.snapshot().config.modules.plugins)
        adapter_signature = plugins.loaded_signature()
        changed('adapters')
      end
    end })
    vim.api.nvim_create_autocmd('PackChanged', { group = group, callback = function(event)
      local data = event.data or {}
      local path = data.path and (vim.uv.fs_realpath(data.path) or data.path)
      if path == paths.root and (data.kind == 'update' or data.kind == 'install') then
        M.request('pack')
      elseif require('nvim-zh.plugins').package_changed(data) then
        changed('adapters')
      end
    end })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function() M.stop() end })
  end
  return M.refresh()
end

function M.info()
  return vim.tbl_extend('force', vim.deepcopy(state), { config_file = config_file.info() })
end

function M.stop()
  stopped = true
  operation = operation + 1
  busy, queued = false, false
  local pending = callbacks
  callbacks = {}
  for _, cb in ipairs(pending) do
    pcall(cb.fn, { ok = false, status = 'cancelled', error_code = 'stopped', error = '同步已取消',
      restart_required = state.restart_required or false, task_id = cb.id })
  end
  if timer then timer:stop(); timer:close(); timer = nil end
  if group then pcall(vim.api.nvim_del_augroup_by_id, group); group = nil end
  local ok, err = native_backend.stop()
  state.status = ok and 'disabled' or 'restore_failed'
  state.error = not ok and tostring(err) or nil
  state.generation = state.generation + 1
  changed('stop')
  return ok, err
end
return M
