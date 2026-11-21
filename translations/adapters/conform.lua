local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'conform'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
}

local slots = {
  setup = {
    module = 'conform',
    method = 'setup',
    surface = 'notifications',
    records = {},
    generation = nil,
  },
  resolve_formatters = {
    module = 'conform',
    method = 'resolve_formatters',
    surface = 'notifications',
    records = {},
    generation = nil,
  },
  format = {
    module = 'conform',
    method = 'format',
    surface = 'notifications',
    records = {},
    generation = nil,
  },
  list_all_formatters = {
    module = 'conform',
    method = 'list_all_formatters',
    surface = 'notifications',
    records = {},
    generation = nil,
  },
  show_window = {
    module = 'conform.health',
    method = 'show_window',
    surface = 'health',
    records = {},
    generation = nil,
  },
  health_check = {
    module = 'conform.health',
    method = 'check',
    surface = 'health',
    records = {},
    generation = nil,
  },
}

local SLOT_ORDER = {
  'setup',
  'resolve_formatters',
  'format',
  'list_all_formatters',
  'show_window',
  'health_check',
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

local function slot_enabled(slot, generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and slot.generation ~= nil and rawequal(slot.generation, generation)
    and rawequal(package.loaded[slot.module], generation)
    and common.active(slot.records, slot.method)
    and verify(slot.surface) ~= nil
end

local function translate_notification(msg)
  if type(msg) ~= 'string' or msg == '' then return msg end
  local name, reason = msg:match("^Formatter '([^']+)' unavailable: (.+)$")
  if name and reason then
    local translated_reason = translate('status', reason)
    return translate('notification', ("Formatter '%s' unavailable: %s"):format(name, translated_reason))
  end
  return translate('notification', msg)
end

local function translate_info_line(line)
  if type(line) ~= 'string' or line == '' then return line end
  local name, reason = line:match('^([^%s]+) unavailable: (.+)$')
  if name and reason then
    local translated_reason = translate('status', reason)
    return translate('info', ('%s unavailable: %s'):format(name, translated_reason))
  end
  local err_name, err_reason = line:match('^([^%s]+) error: (.+)$')
  if err_name and err_reason then
    local translated_reason = translate('status', err_reason)
    return translate('info', ('%s error: %s'):format(err_name, translated_reason))
  end
  return translate('info', line)
end

local function translate_health_message(msg)
  if type(msg) ~= 'string' or msg == '' then return msg end
  local name, reason = msg:match('^([^%s]+) unavailable: (.+)$')
  if name and reason then
    local translated_reason = translate('status', reason)
    return translate('health', ('%s unavailable: %s'):format(name, translated_reason))
  end
  return translate('health', msg)
end

local function with_scoped_notify(fn, ...)
  local prev_notify = vim.notify
  local prev_notify_once = vim.notify_once
  local prev_schedule = vim.schedule

  local function wrap_notify(original)
    return function(msg, level, opts)
      return original(translate_notification(msg), level, opts)
    end
  end

  local notify_proxy = wrap_notify(prev_notify)
  local notify_once_proxy = type(prev_notify_once) == 'function' and wrap_notify(prev_notify_once) or nil

  local schedule_proxy
  schedule_proxy = function(cb)
    return prev_schedule(function(...)
      local cur_notify = vim.notify
      local cur_notify_once = vim.notify_once
      vim.notify = wrap_notify(cur_notify)
      if type(cur_notify_once) == 'function' then
        vim.notify_once = wrap_notify(cur_notify_once)
      end
      local results = common.pack(pcall(cb, ...))
      vim.notify = cur_notify
      vim.notify_once = cur_notify_once
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end)
  end

  vim.notify = notify_proxy
  if notify_once_proxy then vim.notify_once = notify_once_proxy end
  vim.schedule = schedule_proxy

  local results = common.pack(pcall(fn, ...))

  if vim.notify == notify_proxy then vim.notify = prev_notify end
  if notify_once_proxy and vim.notify_once == notify_once_proxy then vim.notify_once = prev_notify_once end
  if vim.schedule == schedule_proxy then vim.schedule = prev_schedule end

  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local active_info_hook = false

local function install_info_buffer_projection(one_shot)
  if active_info_hook then return function() end end
  active_info_hook = true
  local prev_set_lines = vim.api.nvim_buf_set_lines
  local prev_set_extmark = vim.api.nvim_buf_set_extmark
  local target_buf = nil
  local translated_by_row = {}

  local set_lines_proxy
  local set_extmark_proxy

  local function restore()
    if vim.api.nvim_buf_set_lines == set_lines_proxy then
      vim.api.nvim_buf_set_lines = prev_set_lines
    end
    if vim.api.nvim_buf_set_extmark == set_extmark_proxy then
      vim.api.nvim_buf_set_extmark = prev_set_extmark
    end
    active_info_hook = false
  end

  set_lines_proxy = function(bufnr, start, end_, strict, replacement)
    if target_buf == nil and start == 0 and end_ == -1 and type(replacement) == 'table' then
      target_buf = bufnr
      local projected = {}
      for i, line in ipairs(replacement) do
        projected[i] = translate_info_line(line)
        translated_by_row[i - 1] = projected[i]
      end
      return prev_set_lines(bufnr, start, end_, strict, projected)
    end
    return prev_set_lines(bufnr, start, end_, strict, replacement)
  end

  set_extmark_proxy = function(bufnr, ns, line, col, opts)
    if bufnr == target_buf and type(opts) == 'table' then
      local text = translated_by_row[line] or ''
      local len = #text
      local new_opts = common.copy(opts)
      local new_col = col
      if new_opts.hl_group == 'Title' and col == 0 then
        local colon_start, colon_end = text:find('：', 1, true)
        if colon_end and colon_end < len then
          new_opts.end_col = colon_end
        else
          new_opts.end_col = len
        end
      else
        if new_col > len then new_col = len end
        if type(new_opts.end_col) == 'number' and new_opts.end_col > len then
          new_opts.end_col = len
        end
      end
      return prev_set_extmark(bufnr, ns, line, new_col, new_opts)
    end
    return prev_set_extmark(bufnr, ns, line, col, opts)
  end

  vim.api.nvim_buf_set_lines = set_lines_proxy
  vim.api.nvim_buf_set_extmark = set_extmark_proxy

  if one_shot then
    vim.schedule(restore)
  end
  return restore
end

local sync_slot

slots.setup.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.setup, generation) then return original(...) end
    return with_scoped_notify(original, ...)
  end
end

slots.resolve_formatters.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.resolve_formatters, generation) then return original(...) end
    return with_scoped_notify(original, ...)
  end
end

slots.format.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.format, generation) then return original(...) end
    return with_scoped_notify(original, ...)
  end
end

slots.list_all_formatters.factory = function(original, generation)
  return function(...)
    if slot_enabled(slots.list_all_formatters, generation) then
      if type(package.loaded['conform.health']) == 'table' then
        sync_slot(slots.show_window)
        sync_slot(slots.health_check)
      end
      local caller = debug.getinfo(2, 'S')
      if caller and type(caller.source) == 'string' and caller.source:find('lua/conform/health.lua', 1, true)
          and not active_info_hook and verify('health') ~= nil then
        install_info_buffer_projection(true)
      end
    end
    return original(...)
  end
end

slots.show_window.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.show_window, generation) then return original(...) end
    local restore = install_info_buffer_projection(false)
    local results = common.pack(pcall(original, ...))
    restore()
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

slots.health_check.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.health_check, generation) or type(vim.health) ~= 'table' then
      return original(...)
    end
    local previous = vim.health
    local proxy = setmetatable({}, { __index = previous })
    for _, method in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
      local original_method = previous[method]
      if type(original_method) == 'function' then
        proxy[method] = function(message, ...)
          return original_method(translate_health_message(message), ...)
        end
      end
    end
    vim.health = proxy
    local results = common.pack(pcall(original, ...))
    if vim.health == proxy then vim.health = previous end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

sync_slot = function(slot)
  local current = package.loaded[slot.module]
  if current ~= slot.generation then
    if slot.generation ~= nil then common.unwrap(slot.records, slot.method) end
    slot.records = {}
    slot.generation = current
  end
  if type(current) ~= 'table' or type(current[slot.method]) ~= 'function' then return end
  common.wrap(slot.records, slot.method, function()
    return current[slot.method]
  end, function(value)
    current[slot.method] = value
  end, function(original)
    return slot.factory(original, current)
  end)
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = true
  for _, name in ipairs(SLOT_ORDER) do
    sync_slot(slots[name])
  end
end

function M.detach()
  state.enabled = false
  for _, name in ipairs(SLOT_ORDER) do
    local slot = slots[name]
    common.unwrap(slot.records, slot.method)
    slot.records = {}
    slot.generation = nil
  end
end

function M.signature()
  local values = {}
  for _, name in ipairs(SLOT_ORDER) do
    local slot = slots[name]
    local mod = package.loaded[slot.module]
    values[#values + 1] = tostring(mod)
    values[#values + 1] = type(mod) == 'table' and tostring(mod[slot.method]) or ''
  end
  return table.concat(values, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local notify_verified, notify_why = verify('notifications')
  local health_verified, health_why = verify('health')

  local notify_active = enabled and notify_verified ~= nil and (
    common.active(slots.format.records, 'format')
    or common.active(slots.resolve_formatters.records, 'resolve_formatters')
    or common.active(slots.setup.records, 'setup')
  )
  local health_active = enabled and health_verified ~= nil and (
    common.active(slots.show_window.records, 'show_window')
    or common.active(slots.health_check.records, 'check')
  )

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(slots.format.records, 'format') == 'external_override'
      or common.reason(slots.show_window.records, 'show_window') == 'external_override' then
    reason = 'external_override'
  elseif notify_active or health_active then
    reason = nil
  elseif package.loaded['conform'] == nil and package.loaded['conform.health'] == nil then
    reason = 'not_loaded'
  else
    reason = notify_why or health_why or common.reason(slots.format.records, 'format')
  end

  return {
    active = notify_active or health_active,
    reason = reason,
    seam = 'conform.health.show_window; conform.health.check; conform.setup/resolve_formatters/format scoped notification projection',
    domain = DOMAIN,
    notifications = {
      active = notify_active,
      reason = notify_verified and common.reason(slots.format.records, 'format') or notify_why,
    },
    health = {
      active = health_active,
      reason = health_verified and common.reason(slots.show_window.records, 'show_window') or health_why,
    },
  }
end

return M
