local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'nvim-treesitter'
local AUGROUP = 'NvimZhTreesitterAdapter'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
  log_generation = nil,
  log_records = {},
  health_generation = nil,
  health_records = {},
}

local function translate(context, text)
  if type(state.ctx) ~= 'table' or type(text) ~= 'string' or text == '' then return text end
  return state.ctx.translate(DOMAIN, context, text)
end

local function verify(surface)
  local ctx = state.ctx
  if type(ctx) ~= 'table' then return nil, 'not_loaded' end
  if type(ctx.verify) ~= 'function' then return { kind = 'offline' }, nil end
  return ctx.verify(surface)
end

local function log_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and state.log_generation ~= nil and rawequal(state.log_generation, generation)
    and rawequal(package.loaded['nvim-treesitter.log'], generation)
    and verify('notifications') ~= nil
end

local function health_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and state.health_generation ~= nil and rawequal(state.health_generation, generation)
    and rawequal(package.loaded['nvim-treesitter.health'], generation)
    and common.active(state.health_records, 'check')
    and verify('health') ~= nil
end

local function wrap_logger_method(method, original, generation)
  return function(self, fmt, ...)
    if not log_enabled(generation) or not common.active(state.log_records, method) or type(fmt) ~= 'string' then
      return original(self, fmt, ...)
    end
    local formatted = fmt
    if select('#', ...) > 0 then
      local ok, res = pcall(string.format, fmt, ...)
      if not ok then return original(self, fmt, ...) end
      formatted = res
    end
    local translated = translate('log', formatted)
    local escaped = (translated:gsub('%%', '%%%%'))
    return original(self, escaped)
  end
end

local function sync_log()
  local current = package.loaded['nvim-treesitter.log']
  if current ~= state.log_generation then
    if state.log_generation ~= nil then
      for _, method in ipairs({ 'info', 'warn', 'error' }) do
        common.unwrap(state.log_records, method)
      end
    end
    state.log_records = {}
    state.log_generation = current
  end
  if type(current) ~= 'table' or type(current.Logger) ~= 'table' then return end
  local logger = current.Logger
  for _, method in ipairs({ 'info', 'warn', 'error' }) do
    if type(logger[method]) == 'function' then
      common.wrap(state.log_records, method, function()
        return logger[method]
      end, function(value)
        logger[method] = value
      end, function(original)
        return wrap_logger_method(method, original, current)
      end)
    end
  end
end

local function sync_health()
  local current = package.loaded['nvim-treesitter.health']
  if current ~= state.health_generation then
    if state.health_generation ~= nil then
      common.unwrap(state.health_records, 'check')
    end
    state.health_records = {}
    state.health_generation = current
  end
  if type(current) ~= 'table' or type(current.check) ~= 'function' then return end
  common.wrap(state.health_records, 'check', function()
    return current.check
  end, function(value)
    current.check = value
  end, function(original)
    return function(...)
      if not health_enabled(current) or type(vim.health) ~= 'table' then
        return original(...)
      end
      local previous = vim.health
      local proxy = setmetatable({}, { __index = previous })
      for _, method in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
        local original_method = previous[method]
        if type(original_method) == 'function' then
          proxy[method] = function(message, ...)
            return original_method(translate('health', message), ...)
          end
        end
      end
      vim.health = proxy
      local results = common.pack(pcall(original, ...))
      if vim.health == proxy then vim.health = previous end
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end
  end)
end

local function setup_autocmd()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  if not state.enabled then return end
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'TSUpdate',
    desc = 'nvim-zh: attach nvim-treesitter logger on parser operations',
    callback = function()
      if state.enabled then sync_log() end
    end,
  })
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = true
  setup_autocmd()
  sync_log()
  sync_health()
end

function M.detach()
  state.enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  for _, method in ipairs({ 'info', 'warn', 'error' }) do
    common.unwrap(state.log_records, method)
  end
  state.log_records = {}
  state.log_generation = nil
  common.unwrap(state.health_records, 'check')
  state.health_records = {}
  state.health_generation = nil
end

function M.signature()
  local log_mod = package.loaded['nvim-treesitter.log']
  local logger = type(log_mod) == 'table' and log_mod.Logger or nil
  local health_mod = package.loaded['nvim-treesitter.health']
  return table.concat({
    tostring(package.loaded['nvim-treesitter']),
    tostring(log_mod),
    type(logger) == 'table' and tostring(logger.info) or '',
    type(logger) == 'table' and tostring(logger.warn) or '',
    type(logger) == 'table' and tostring(logger.error) or '',
    tostring(health_mod),
    type(health_mod) == 'table' and tostring(health_mod.check) or '',
  }, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local notify_verified, notify_why = verify('notifications')
  local health_verified, health_why = verify('health')

  local log_wrapped = common.active(state.log_records, 'info')
    and common.active(state.log_records, 'warn')
    and common.active(state.log_records, 'error')
  local notify_active = enabled and notify_verified ~= nil and log_wrapped
  local health_active = enabled and health_verified ~= nil and common.active(state.health_records, 'check')

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(state.log_records, 'info') == 'external_override'
      or common.reason(state.health_records, 'check') == 'external_override' then
    reason = 'external_override'
  elseif notify_active or health_active then
    reason = nil
  elseif package.loaded['nvim-treesitter.log'] == nil and package.loaded['nvim-treesitter.health'] == nil then
    reason = 'not_loaded'
  else
    reason = notify_why or health_why or common.reason(state.log_records, 'info')
  end

  return {
    active = notify_active or health_active,
    reason = reason,
    seam = 'nvim-treesitter.log.Logger.{info,warn,error}; User TSUpdate lifecycle hook; nvim-treesitter.health.check',
    domain = DOMAIN,
    notifications = {
      active = notify_active,
      reason = notify_verified and common.reason(state.log_records, 'info') or notify_why,
    },
    health = {
      active = health_active,
      reason = health_verified and common.reason(state.health_records, 'check') or health_why,
    },
  }
end

return M
