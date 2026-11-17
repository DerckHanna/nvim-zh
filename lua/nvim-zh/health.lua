local M = {}

local function collect()
  local zh = require('nvim-zh')
  local config = zh.info().config
  local results = {
    {
      name = 'setup',
      status = zh.info().configured and 'ok' or 'info',
      message = zh.info().configured and 'setup() 已执行' or '尚未执行 setup()；仅显示只读检查',
    },
  }
  if config.modules.core.enabled then
    vim.list_extend(results, require('nvim-zh.native').check())
  end
  vim.list_extend(results, require('nvim-zh.help').check(config.modules.help))
  local ui = require('nvim-zh.ui').info()
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
  local plugins = require('nvim-zh.plugins').info()
  for _, name in ipairs({ 'which-key', 'telescope', 'lazy.nvim', 'nvim-tree', 'nvim-cmp' }) do
    local adapter = plugins[name]
    local status = adapter.active and 'ok'
      or adapter.enabled and adapter.reason ~= 'not_loaded' and 'warn' or 'info'
    table.insert(results, {
      name = 'plugins.' .. name,
      status = status,
      message = adapter.active and ('已启用：' .. adapter.seam) or adapter.enabled
        and ('已降级：' .. tostring(adapter.reason)) or ('已禁用/未加载：' .. tostring(adapter.reason)),
    })
  end
  local diagnostics = require('nvim-zh.diagnostics').info()
  for _, name in ipairs({ 'virtual_text', 'virtual_lines', 'float' }) do
    local adapter = diagnostics[name]
    local status = adapter.active and 'ok' or adapter.enabled and 'warn' or 'info'
    table.insert(results, {
      name = 'diagnostics.' .. name,
      status = status,
      message = adapter.active and '已启用：clangd 显示层'
        or adapter.enabled and ('已降级：' .. tostring(adapter.reason)) or '已禁用',
    })
  end
  local lsp = require('nvim-zh.lsp').info()
  local expected = {}
  if lsp.messages then
    table.insert(expected, 'window/showMessage')
    table.insert(expected, 'window/showMessageRequest')
  end
  if lsp.progress then table.insert(expected, '$/progress') end
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
    message = ('messages=%s progress=%s window/logMessage=原文%s'):format(
      tostring(lsp.messages), tostring(lsp.progress), detail),
  })
  return results
end

function M.collect() return collect() end

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
