local M = {}
local cache = { status = 'unread', results = {} }
local task = 0
local pending

local function deliver(callback, result)
  if not callback then return end
  local ok, err = pcall(callback, result)
  if not ok then vim.schedule(function() vim.notify('nvim-zh：检查回调出错：' .. tostring(err), vim.log.levels.WARN) end) end
end

local function cancel(reason)
  local current = pending
  pending = nil
  if current then
    deliver(current.fn, { ok = false, status = 'cancelled', error_code = reason,
      error = reason == 'superseded' and '检查已被更新的检查取代' or '检查已取消', task_id = current.id })
  end
end

local function collect()
  local snapshot = require('nvim-zh.status').get()
  local config = snapshot.config
  local results = {
    {
      name = 'setup',
      status = snapshot.configured and 'ok' or 'info',
      message = snapshot.configured and 'setup() 已执行' or '尚未执行 setup()；仅显示只读检查',
    },
  }
  local runtime = snapshot.runtime
  table.insert(results, { name = 'resources', status = runtime.status == 'error' and 'error'
    or runtime.status == 'ok' and 'ok' or 'info', message = runtime.error or runtime.status })
  table.insert(results, { name = 'config.file', status = runtime.config_file.status == 'error' and 'warn' or 'info',
    message = runtime.config_file.error or runtime.config_file.status })
  if config.modules.core.enabled then
    vim.list_extend(results, require('nvim-zh.native').check())
  end
  vim.list_extend(results, require('nvim-zh.help').check(config.modules.help))
  local ui = snapshot.ui
  for _, name in ipairs({ 'notify', 'notify_once', 'input', 'select', 'select_items', 'echo' }) do
    local adapter = ui[name]
    local status = adapter.active and 'ok' or adapter.enabled and 'warn' or 'info'
    table.insert(results, {
      name = 'ui.' .. name,
      status = status,
      message = adapter.active and '已启用' or adapter.enabled
        and ('已降级：' .. tostring(adapter.reason)) or '已禁用',
    })
  end
  local plugins = snapshot.adapters
  for _, id in ipairs(vim.fn.sort(vim.tbl_keys(snapshot.packs))) do
    local pack = snapshot.packs[id]
    local reason = pack.reason or (pack.job and pack.job.phase == '失败' and pack.job.message)
    table.insert(results, {
      name = 'packs.' .. id,
      status = (pack.error or (pack.job and pack.job.phase == '失败')) and 'warn'
        or pack.active and 'ok' or 'info',
      message = reason or (pack.active and ('活动版本 ' .. pack.active))
        or (pack.job and pack.job.phase) or '已登记',
    })
  end
  local plugin_names = vim.tbl_keys(plugins)
  table.sort(plugin_names)
  for _, name in ipairs(plugin_names) do
    local adapter = plugins[name]
    local status = adapter.active and 'ok'
      or adapter.enabled and adapter.reason ~= 'not_loaded' and 'warn' or 'info'
    table.insert(results, {
      name = 'adapters.' .. name,
      status = status,
      message = adapter.active and ('已启用：' .. adapter.seam) or adapter.enabled
        and ('已降级：' .. tostring(adapter.reason)) or ('已禁用/未加载：' .. tostring(adapter.reason)),
    })
    for _, surface in ipairs(vim.fn.sort(vim.tbl_keys(adapter.surfaces))) do
      local display = adapter.surfaces[surface]
      table.insert(results, {
        name = 'adapters.' .. name .. '.' .. surface,
        status = display.active and 'ok' or 'info',
        message = display.status .. (display.evidence and (' · ' .. display.evidence.kind) or ''),
      })
    end
  end
  local diagnostics = snapshot.diagnostics
  for _, name in ipairs({ 'virtual_text', 'virtual_lines', 'float', 'setqflist', 'setloclist' }) do
    local adapter = diagnostics[name]
    local status = adapter.active and 'ok' or adapter.enabled and 'warn' or 'info'
    table.insert(results, {
      name = 'diagnostics.' .. name,
      status = status,
      message = adapter.active and '已启用：clangd 显示层'
        or adapter.enabled and ('已降级：' .. tostring(adapter.reason)) or '已禁用',
    })
  end
  local lsp = snapshot.lsp
  local expected = {}
  if lsp.messages then
    table.insert(expected, 'window/showMessage')
    table.insert(expected, 'window/showMessageRequest')
  end
  if lsp.progress then table.insert(expected, '$/progress') end
  if lsp.hints then table.insert(expected, 'buf_request_all') end
  local degraded = {}
  for _, method in ipairs(expected) do
    local adapter = lsp[method]
    if not adapter or not adapter.active then
      table.insert(degraded, method .. '=' .. tostring(adapter and adapter.reason or 'unavailable'))
    end
  end
  local status = #expected > 0 and (#degraded > 0 and 'warn' or 'ok') or 'info'
  local detail = #degraded > 0 and ('；降级：' .. table.concat(degraded, ',')) or ''
  table.insert(results, {
    name = 'lsp.clangd',
    status = status,
    message = ('messages=%s progress=%s hints=%s window/logMessage=原文%s'):format(
      tostring(lsp.messages), tostring(lsp.progress), tostring(lsp.hints), detail),
  })
  return results
end

function M.collect() return collect() end

function M.run(callback)
  assert(callback == nil or type(callback) == 'function', 'check callback must be function')
  cancel('superseded')
  task = task + 1
  local id = task
  pending = callback and { fn = callback, id = id } or nil
  cache.status = 'checking'
  vim.schedule(function()
    if id ~= task then return end
    local ok, results = pcall(collect)
    if id ~= task then return end
    cache = { status = ok and 'complete' or 'error', checked_at = os.time(), results = ok and results or {},
      error = not ok and tostring(results) or nil }
    local current = pending
    pending = nil
    if current and current.id == id then
      local degraded = false
      if ok then
        for _, result in ipairs(results) do
          if result.status == 'warn' or result.status == 'error' then degraded = true; break end
        end
      end
      deliver(current.fn, { ok = ok, status = ok and (degraded and 'degraded' or 'ok') or 'error',
        error_code = not ok and 'check_failed' or nil, task_id = id,
        results = ok and results or nil, error = not ok and tostring(results) or nil })
    end
  end)
  return id
end

function M.stop()
  task = task + 1
  cancel('stopped')
  cache.status = 'cancelled'
end

function M.info() return vim.deepcopy(cache) end

function M.show()
  local results = collect()
  local lines = { 'nvim-zh 检查结果：' }
  local level = vim.log.levels.INFO
  for _, result in ipairs(results) do
    table.insert(lines, ('[%s] %s: %s'):format(result.status, result.name, result.message))
    if result.status == 'error' then level = vim.log.levels.ERROR
    elseif result.status == 'warn' and level ~= vim.log.levels.ERROR then level = vim.log.levels.WARN end
  end
  vim.notify(table.concat(lines, '\n'), level)
  return results
end

function M.check()
  vim.health.start('nvim-zh')
  for _, result in ipairs(collect()) do
    vim.health[result.status == 'error' and 'error' or result.status == 'warn' and 'warn' or result.status == 'info' and 'info' or 'ok'](result.name .. ': ' .. result.message)
  end
end

return M
