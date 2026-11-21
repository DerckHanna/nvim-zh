local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'blink-cmp'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
  release_source = nil,
  source_error = nil,
  utils_generation = nil,
  utils_records = {},
  build_generation = nil,
  build_records = {},
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

local function notify_enabled(generation, module_name)
  return state.enabled and state.ctx and state.ctx.enabled()
    and generation ~= nil and rawequal(package.loaded[module_name], generation)
    and verify('notifications') ~= nil
end

local function health_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and state.health_generation ~= nil and rawequal(state.health_generation, generation)
    and rawequal(package.loaded['blink.cmp.health'], generation)
    and common.active(state.health_records, 'check')
    and verify('health') ~= nil
end

local function project_chunks(msg)
  if type(msg) ~= 'table' then return msg end
  local projected = {}
  for i, chunk in ipairs(msg) do
    if type(chunk) == 'table' and type(chunk[1]) == 'string' then
      local copy = common.copy(chunk)
      copy[1] = translate('notification', chunk[1])
      projected[i] = copy
    else
      projected[i] = chunk
    end
  end
  return projected
end

local function sync_utils()
  local current = package.loaded['blink.cmp.lib.utils']
  if current ~= state.utils_generation then
    if state.utils_generation ~= nil then
      common.unwrap(state.utils_records, 'notify')
    end
    state.utils_records = {}
    state.utils_generation = current
  end
  if type(current) ~= 'table' or type(current.notify) ~= 'function' then return end
  common.wrap(state.utils_records, 'notify', function()
    return current.notify
  end, function(value)
    current.notify = value
  end, function(original)
    return function(msg, lvl, ...)
      if notify_enabled(current, 'blink.cmp.lib.utils') and common.active(state.utils_records, 'notify') then
        msg = project_chunks(msg)
      end
      return original(msg, lvl, ...)
    end
  end)
end

local function sync_build()
  local current = package.loaded['blink.cmp.fuzzy.build']
  if current ~= state.build_generation then
    if state.build_generation ~= nil then
      common.unwrap(state.build_records, 'build')
      common.unwrap(state.build_records, 'build_log')
    end
    state.build_records = {}
    state.build_generation = current
  end
  if type(current) ~= 'table' then return end
  for _, method in ipairs({ 'build', 'build_log' }) do
    if type(current[method]) == 'function' then
      common.wrap(state.build_records, method, function()
        return current[method]
      end, function(value)
        current[method] = value
      end, function(original)
        return function(...)
          if state.enabled then sync_utils() end
          return original(...)
        end
      end)
    end
  end
end

local function sync_health()
  local current = package.loaded['blink.cmp.health']
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

local function ensure_source(ctx)
  if state.release_source or type(ctx.register_source) ~= 'function' then return end
  local ok, release = pcall(ctx.register_source, {
    title = 'blink.cmp',
    domain = DOMAIN,
    context = 'notification',
  })
  if ok then
    state.release_source = release
    state.source_error = nil
  else
    state.source_error = tostring(release)
  end
end

local function release_source()
  if state.release_source then
    pcall(state.release_source)
    state.release_source = nil
  end
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = true
  ensure_source(ctx)
  sync_utils()
  sync_build()
  sync_health()
end

function M.detach()
  state.enabled = false
  release_source()
  common.unwrap(state.utils_records, 'notify')
  state.utils_records = {}
  state.utils_generation = nil
  common.unwrap(state.build_records, 'build')
  common.unwrap(state.build_records, 'build_log')
  state.build_records = {}
  state.build_generation = nil
  common.unwrap(state.health_records, 'check')
  state.health_records = {}
  state.health_generation = nil
end

function M.signature()
  local utils = package.loaded['blink.cmp.lib.utils']
  local build = package.loaded['blink.cmp.fuzzy.build']
  local health = package.loaded['blink.cmp.health']
  return table.concat({
    tostring(package.loaded['blink.cmp']),
    tostring(utils),
    type(utils) == 'table' and tostring(utils.notify) or '',
    tostring(build),
    type(build) == 'table' and tostring(build.build_log) or '',
    tostring(health),
    type(health) == 'table' and tostring(health.check) or '',
  }, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local notify_verified, notify_why = verify('notifications')
  local health_verified, health_why = verify('health')

  local notify_active = enabled and notify_verified ~= nil and (
    common.active(state.utils_records, 'notify')
    or common.active(state.build_records, 'build_log')
  )
  local health_active = enabled and health_verified ~= nil and common.active(state.health_records, 'check')

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(state.utils_records, 'notify') == 'external_override'
      or common.reason(state.health_records, 'check') == 'external_override' then
    reason = 'external_override'
  elseif notify_active or health_active then
    reason = nil
  elseif package.loaded['blink.cmp.lib.utils'] == nil and package.loaded['blink.cmp.health'] == nil then
    reason = 'not_loaded'
  else
    reason = notify_why or health_why or common.reason(state.utils_records, 'notify')
  end

  return {
    active = notify_active or health_active,
    reason = reason,
    seam = 'blink.cmp.lib.utils.notify; vim.notify:title=blink.cmp; blink.cmp.health.check',
    domain = DOMAIN,
    notifications = {
      active = notify_active,
      reason = notify_verified and common.reason(state.utils_records, 'notify') or notify_why,
      error = state.source_error,
    },
    health = {
      active = health_active,
      reason = health_verified and common.reason(state.health_records, 'check') or health_why,
    },
  }
end

return M
