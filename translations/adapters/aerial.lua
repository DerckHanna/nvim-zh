local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'aerial'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
}

local slots = {
  toggle = {
    module = 'aerial',
    method = 'toggle',
    surface = 'command_info',
    records = {},
    generation = nil,
  },
  open = {
    module = 'aerial',
    method = 'open',
    surface = 'command_info',
    records = {},
    generation = nil,
  },
  sync_load = {
    module = 'aerial',
    method = 'sync_load',
    surface = 'command_info',
    records = {},
    generation = nil,
  },
  aerial_info = {
    module = 'aerial',
    method = 'info',
    surface = 'command_info',
    records = {},
    generation = nil,
  },
  command_info = {
    module = 'aerial.command',
    method = 'info',
    surface = 'command_info',
    records = {},
    generation = nil,
  },
  log_support_err = {
    module = 'aerial.backends',
    method = 'log_support_err',
    surface = 'command_info',
    records = {},
    generation = nil,
  },
  render_centered_text = {
    module = 'aerial.util',
    method = 'render_centered_text',
    surface = 'outline_window',
    records = {},
    generation = nil,
  },
  set_keymaps = {
    module = 'aerial.keymap_util',
    method = 'set_keymaps',
    surface = 'outline_window',
    records = {},
    generation = nil,
  },
  show_help = {
    module = 'aerial.keymap_util',
    method = 'show_help',
    surface = 'outline_window',
    records = {},
    generation = nil,
  },
}

local SLOT_ORDER = {
  'toggle',
  'open',
  'sync_load',
  'aerial_info',
  'command_info',
  'log_support_err',
  'render_centered_text',
  'set_keymaps',
  'show_help',
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

local function translate_outline_line(line)
  if type(line) ~= 'string' or line == '' then return line end
  local name, reason = line:match('^([^%s]+) %(not supported%) %[(.+)%]$')
  if name and reason then
    local translated_reason = translate('status', reason)
    return translate('outline', ('%s (not supported) [%s]'):format(name, translated_reason))
  end
  return translate('outline', line)
end

local function translate_info_line(line)
  if type(line) ~= 'string' or line == '' then return line end
  local ignore_reason = line:match("^Aerial ignores this window: (.+)%. See the 'ignore' config in :help aerial%-options$")
  if ignore_reason then
    local translated_reason = translate('status', ignore_reason)
    return translate('info', ("Aerial ignores this window: %s. See the 'ignore' config in :help aerial-options"):format(translated_reason))
  end
  local name, reason, attached = line:match('^  ([^%s]+) %(not supported%) %[(.+)%](.*)$')
  if name and reason then
    local translated_reason = translate('status', reason)
    return translate('info', ('  %s (not supported) [%s]%s'):format(name, translated_reason, attached or ''))
  end
  return translate('info', line)
end

local active_print_hook = false
local function install_print_projection(one_shot)
  if active_print_hook then return function() end end
  active_print_hook = true
  local prev_print = _G.print
  local print_proxy
  local function restore()
    if _G.print == print_proxy then
      _G.print = prev_print
    end
    active_print_hook = false
  end
  print_proxy = function(first, ...)
    if select('#', ...) == 0 and type(first) == 'string' then
      return prev_print(translate_info_line(first))
    end
    return prev_print(first, ...)
  end
  _G.print = print_proxy
  if one_shot then
    vim.schedule(restore)
  end
  return restore
end

local sync_slot
local function sync_all()
  for _, name in ipairs(SLOT_ORDER) do
    sync_slot(slots[name])
  end
end

local function ensure_submodules_synced(generation)
  if type(generation.sync_load) == 'function' then
    pcall(generation.sync_load)
  end
  pcall(require, 'aerial.util')
  pcall(require, 'aerial.keymap_util')
  pcall(require, 'aerial.command')
  pcall(require, 'aerial.backends')
  sync_all()
end

slots.toggle.factory = function(original, generation)
  return function(...)
    if slot_enabled(slots.toggle, generation) then
      ensure_submodules_synced(generation)
    end
    return original(...)
  end
end

slots.open.factory = function(original, generation)
  return function(...)
    if slot_enabled(slots.open, generation) then
      ensure_submodules_synced(generation)
    end
    return original(...)
  end
end

slots.sync_load.factory = function(original, generation)
  return function(...)
    local results = common.pack(original(...))
    if slot_enabled(slots.sync_load, generation) then
      pcall(require, 'aerial.util')
      pcall(require, 'aerial.keymap_util')
      pcall(require, 'aerial.command')
      pcall(require, 'aerial.backends')
      sync_all()
    end
    return unpack(results, 1, results.n)
  end
end

slots.aerial_info.factory = function(original, generation)
  return function(...)
    if slot_enabled(slots.aerial_info, generation) then
      ensure_submodules_synced(generation)
      local caller = debug.getinfo(2, 'S')
      if caller and type(caller.source) == 'string' and caller.source:find('lua/aerial/command.lua', 1, true)
          and not active_print_hook then
        install_print_projection(true)
      end
    end
    return original(...)
  end
end

slots.command_info.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.command_info, generation) then return original(...) end
    local restore = install_print_projection(false)
    local results = common.pack(pcall(original, ...))
    restore()
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

slots.log_support_err.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.log_support_err, generation) then return original(...) end
    local prev_notify = vim.notify
    local notify_proxy = function(msg, level, opts)
      return prev_notify(translate('notification', msg), level, opts)
    end
    vim.notify = notify_proxy
    local results = common.pack(pcall(original, ...))
    if vim.notify == notify_proxy then vim.notify = prev_notify end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

slots.render_centered_text.factory = function(original, generation)
  return function(bufnr, text, ...)
    if not slot_enabled(slots.render_centered_text, generation) then
      return original(bufnr, text, ...)
    end
    local projected = text
    if type(text) == 'string' then
      projected = translate_outline_line(text)
    elseif type(text) == 'table' then
      projected = {}
      for i, line in ipairs(text) do
        projected[i] = translate_outline_line(line)
      end
    end
    return original(bufnr, projected, ...)
  end
end

slots.set_keymaps.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.set_keymaps, generation) then return original(...) end
    local prev_set = vim.keymap.set
    local set_proxy = function(mode, lhs, rhs, opts)
      if type(opts) == 'table' and type(opts.desc) == 'string' and opts.desc ~= '' then
        local copy = common.copy(opts)
        copy.desc = translate('action', opts.desc)
        opts = copy
      end
      return prev_set(mode, lhs, rhs, opts)
    end
    vim.keymap.set = set_proxy
    local results = common.pack(pcall(original, ...))
    if vim.keymap.set == set_proxy then vim.keymap.set = prev_set end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

slots.show_help.factory = function(original, generation)
  return function(...)
    if not slot_enabled(slots.show_help, generation) then return original(...) end
    local prev_set_lines = vim.api.nvim_buf_set_lines
    local set_lines_proxy
    set_lines_proxy = function(bufnr, start, end_, strict, replacement)
      if start == 0 and end_ == -1 and type(replacement) == 'table' then
        local projected = {}
        for i, line in ipairs(replacement) do
          local prefix, desc = line:match('^( %S+%s%s%s+)(.+)$')
          if prefix and desc then
            projected[i] = prefix .. translate('action', desc)
          else
            projected[i] = line
          end
        end
        return prev_set_lines(bufnr, start, end_, strict, projected)
      end
      return prev_set_lines(bufnr, start, end_, strict, replacement)
    end
    vim.api.nvim_buf_set_lines = set_lines_proxy
    local results = common.pack(pcall(original, ...))
    if vim.api.nvim_buf_set_lines == set_lines_proxy then
      vim.api.nvim_buf_set_lines = prev_set_lines
    end
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
  sync_all()
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
  local cmd_verified, cmd_why = verify('command_info')
  local out_verified, out_why = verify('outline_window')

  local cmd_active = enabled and cmd_verified ~= nil and (
    common.active(slots.toggle.records, 'toggle')
    or common.active(slots.command_info.records, 'info')
  )
  local out_active = enabled and out_verified ~= nil and (
    common.active(slots.render_centered_text.records, 'render_centered_text')
    or common.active(slots.show_help.records, 'show_help')
  )

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(slots.toggle.records, 'toggle') == 'external_override'
      or common.reason(slots.render_centered_text.records, 'render_centered_text') == 'external_override' then
    reason = 'external_override'
  elseif cmd_active or out_active then
    reason = nil
  elseif package.loaded['aerial'] == nil and package.loaded['aerial.util'] == nil then
    reason = 'not_loaded'
  else
    reason = cmd_why or out_why or common.reason(slots.toggle.records, 'toggle')
  end

  return {
    active = cmd_active or out_active,
    reason = reason,
    seam = 'aerial.util.render_centered_text; aerial.keymap_util.set_keymaps/show_help; aerial.command.info; aerial.backends.log_support_err',
    domain = DOMAIN,
    command_info = {
      active = cmd_active,
      reason = cmd_verified and common.reason(slots.toggle.records, 'toggle') or cmd_why,
    },
    outline_window = {
      active = out_active,
      reason = out_verified and common.reason(slots.render_centered_text.records, 'render_centered_text') or out_why,
    },
  }
end

return M
