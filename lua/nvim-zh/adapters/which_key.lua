local common = require('nvim-zh.adapters.common')

local unpack = table.unpack or unpack

local M = {}

local attach_display

local state = {
  active = false,
  reason = 'not_initialized',
  text_records = {},
  plugin_records = {},
  registers_records = {},
}

-- Fixed private footer labels (view.lua:442/445/448). They are appended as
-- " " .. desc segments with the WhichKeySeparator highlight; only that exact
-- shape is projected, at the display-only Text:render boundary.
local FOOTER_LABELS = { close = true, back = true, scroll = true }

local function find_formatter(list, formatter)
  for index, value in ipairs(list) do
    if value == formatter then return index end
  end
  return nil
end

-- A formatter belongs only to the list generation that received it. Keeping its
-- identity lets us clean an old module/list without reclaiming a replacement.
local function clear_formatter(reason, preserve_external)
  local external_config = preserve_external
    and ((state.reason == 'external_override' and state.config) or state.external_config) or nil
  if state.list and state.formatter then
    local index = find_formatter(state.list, state.formatter)
    if index then table.remove(state.list, index) end
  end
  state.config, state.list, state.formatter = nil, nil, nil
  state.external_config = external_config
  state.active, state.reason = false, reason or 'disabled'
end

local function clear_setup(reason, preserve_external)
  local generation = state.setup
  if not generation then return end
  generation.valid = false
  common.unwrap(generation.hooks, 'setup', reason or 'disabled')
  local record = generation.hooks.setup
  if preserve_external and record and record.reason == 'external_override' then
    state.setup = generation
  else
    state.setup = nil
  end
end

local function attach_formatter()
  local config = package.loaded['which-key.config']
  if state.external_config and state.external_config ~= config then state.external_config = nil end
  if state.config and state.config ~= config then clear_formatter('module_replaced', false) end
  if type(config) ~= 'table' then
    state.active, state.reason = false, 'not_loaded'
    return
  end
  if type(config.replace) ~= 'table' or type(config.replace.desc) ~= 'table' then
    state.active, state.reason = false, 'unsupported_api'
    return
  end

  local list = config.replace.desc
  if state.formatter then
    if state.list == list and find_formatter(list, state.formatter) then
      state.active, state.reason = true, nil
    else
      -- Direct replacement/removal is an external choice. Only a subsequent
      -- public setup call may deliberately attach to a rebuilt list.
      state.active, state.reason = false, 'external_override'
    end
    return
  end
  if state.external_config == config then
    state.active, state.reason = false, 'external_override'
    return
  end

  local formatter
  formatter = function(text)
    local ctx = state.ctx
    if not ctx or not ctx.enabled() or not state.active or not rawequal(package.loaded['which-key.config'], config)
      or type(config.replace) ~= 'table' or config.replace.desc ~= list
      or state.config ~= config or state.list ~= list or state.formatter ~= formatter then
      return text
    end
    local ok, translated = pcall(ctx.translate, 'which-key', 'desc', text)
    return ok and type(translated) == 'string' and translated or text
  end
  table.insert(list, formatter)
  state.config, state.list, state.formatter = config, list, formatter
  state.active, state.reason = true, nil
end

local function attach_setup()
  local wk = package.loaded['which-key']
  if state.setup and state.setup.module ~= wk then clear_setup('module_replaced', false) end
  if type(wk) ~= 'table' then return end

  local generation = state.setup
  if not generation then
    generation = { module = wk, hooks = {}, valid = true }
    state.setup = generation
  end

  generation.valid = true
  common.wrap(generation.hooks, 'setup', function()
    return wk.setup
  end, function(value)
    wk.setup = value
  end, function(original)
    local wrapper
    wrapper = function(...)
      -- Do not turn an original setup failure into a successful reattach.
      local results = common.pack(original(...))
      if generation.valid and state.setup == generation and wk.setup == wrapper then
        clear_formatter('setup', false)
        if state.ctx and state.ctx.enabled() then
          attach_formatter()
          attach_display()
        else
          state.reason = 'disabled'
        end
      end
      return unpack(results, 1, results.n)
    end
    return wrapper
  end)
end

-- Version-related display seams below. Each one is gated by ctx.verify on the
-- pinned source digests; without loading evidence the original text renders.

local function verify(surface)
  local ctx = state.ctx
  if type(ctx) ~= 'table' or type(ctx.verify) ~= 'function' then
    return nil, 'unsupported_api'
  end
  return ctx.verify(surface)
end

local function display_enabled(slot, generation)
  local loaded = package.loaded[slot.module]
  return state.ctx and state.ctx.enabled() and state.active
    and rawequal(loaded, generation)
    and common.active(slot.records, slot.method)
    and verify(slot.surface) ~= nil
end

local function project_footer_segment(segment)
  if type(segment) ~= 'table' or segment.hl ~= 'WhichKeySeparator'
    or type(segment.str) ~= 'string' then
    return segment
  end
  local label = segment.str:match('^ (.+)$')
  if not label or not FOOTER_LABELS[label] then return segment end
  local translated = state.ctx.translate('which-key', 'footer', label)
  if translated == label then return segment end
  local str = ' ' .. translated
  return { str = str, hl = segment.hl, width = #str, line = segment.line }
end

-- The footer, popup body and help Text instances all resolve `render` through
-- the shared metatable in text.lua (M.__index = M, text.lua:18/22). Wrapping the
-- module method therefore reaches every instance regardless of when view.lua
-- loaded, and display-only projection is confined to that method (text.lua:109).
-- Only segments shaped exactly like the private footer hints (view.lua:442/445
-- /448: " " .. desc with the WhichKeySeparator highlight) are projected, so the
-- breadcrumb separator, descriptions, keys and plugin columns stay untouched.
local function sync_text()
  local slot = state.text_slot
  local current = package.loaded[slot.module]
  if current ~= slot.generation then
    if slot.generation ~= nil then
      local previous = slot.generation
      slot.generation = nil
      common.unwrap(slot.records, slot.method)
      slot.generation = previous
    end
    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then return end
  end
  if type(current) ~= 'table' then return end
  -- Own Text.render whenever the leaf is loaded; the wrapper stays inert until
  -- verify() succeeds, so an unverified revision keeps rendering the original.
  common.wrap(slot.records, slot.method, function()
    return current[slot.method]
  end, function(value)
    current[slot.method] = value
  end, function(original)
    return function(self, buf, ...)
      if not display_enabled(slot, current) or type(self) ~= 'table'
        or type(self._lines) ~= 'table' then
        return original(self, buf, ...)
      end
      local projected, changed = {}, false
      for index, line in ipairs(self._lines) do
        local copy, line_changed = {}, false
        for position, segment in ipairs(line) do
          local replacement = project_footer_segment(segment)
          if replacement ~= segment then line_changed = true end
          copy[position] = replacement
        end
        projected[index] = copy
        changed = changed or line_changed
      end
      if not changed then return original(self, buf, ...) end
      -- Project a shallow copy: the original Text columns and byte widths are
      -- untouched and highlight offsets are recomputed from the new bytes.
      return original(setmetatable({ _lines = projected, _col = self._col, ns = self.ns,
        _opts = self._opts, _indents = self._indents }, getmetatable(self)), buf, ...)
    end
  end)
  local verified, reason = verify(slot.surface)
  if not verified then
    slot.unavailable = reason
    return
  end
  slot.unavailable = nil
end

-- After which-key's own setup completed, load the footer leaf so the shared
-- render method is owned before the first popup. This never loads which-key
-- itself and never runs before the plugin finished setup.
local function ensure_footer_sources()
  local config = package.loaded['which-key.config']
  if type(config) ~= 'table' or not config.loaded then return end
  if package.loaded['which-key.text'] == nil then pcall(require, 'which-key.text') end
  sync_text()
  -- view.lua is pinned for evidence only: the footer strings live there.
  if package.loaded['which-key.view'] == nil then pcall(require, 'which-key.view') end
  sync_text()
end

state.text_slot = {
  module = 'which-key.text', method = 'render', surface = 'popup_footer',
  records = state.text_records,
}

-- marks.expand builds "file: " .. path descriptions (marks.lua:54). The fixed
-- prefix is plugin-owned; the path payload stays byte-identical. The plugin
-- module is only loaded by which-key's own setup (plugins/init.lua:18), so a
-- leaf require here never forces the plugin itself to load.
local function sync_marks()
  local slot = state.plugin_slot
  local current = package.loaded[slot.module]
  if current == nil then
    -- marks.lua is a leaf loaded by which-key's own plugins.setup. Only after
    -- the plugin finished setup may the adapter load it for a late attach.
    local config = package.loaded['which-key.config']
    if type(config) == 'table' and config.loaded
      and type(config.plugins) == 'table' and config.plugins.marks then
      local ok, loaded = pcall(require, slot.module)
      if ok then current = loaded end
    end
  end
  if current ~= slot.generation then
    if slot.generation ~= nil then
      local previous = slot.generation
      slot.generation = nil
      common.unwrap(slot.records, slot.method)
      slot.generation = previous
    end
    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then return end
  end
  if type(current) ~= 'table' then return end
  local verified, reason = verify(slot.surface)
  if not verified then
    common.unwrap(slot.records, slot.method)
    slot.unavailable = reason
    return
  end
  slot.unavailable = nil
  common.wrap(slot.records, slot.method, function()
    return current[slot.method]
  end, function(value)
    current[slot.method] = value
  end, function(original)
    return function(...)
      local results = common.pack(original(...))
      if display_enabled(slot, current) and type(results[1]) == 'table' then
        local projected = {}
        for index, item in ipairs(results[1]) do
          if type(item) == 'table' and type(item.desc) == 'string'
            and item.desc:sub(1, 6) == 'file: ' then
            local copy = common.copy(item)
            copy.desc = state.ctx.translate('which-key', 'mark_file', item.desc)
            projected[index] = copy
          else
            projected[index] = item
          end
        end
        results[1] = projected
      end
      return unpack(results, 1, results.n)
    end
  end)
end

state.plugin_slot = {
  module = 'which-key.plugins.marks', method = 'expand', surface = 'plugin_labels',
  records = state.plugin_records,
}

-- registers.expand shows a fixed OSC 52 notice as the value column
-- (registers.lua:50). Register contents themselves are user data and are
-- never touched; only the exact synthetic notice is projected.
local function sync_registers()
  local slot = state.registers_slot
  local current = package.loaded[slot.module]
  if current == nil then
    local config = package.loaded['which-key.config']
    if type(config) == 'table' and config.loaded
      and type(config.plugins) == 'table' and config.plugins.registers then
      local ok, loaded = pcall(require, slot.module)
      if ok then current = loaded end
    end
  end
  if current ~= slot.generation then
    if slot.generation ~= nil then
      local previous = slot.generation
      slot.generation = nil
      common.unwrap(slot.records, slot.method)
      slot.generation = previous
    end
    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then return end
  end
  if type(current) ~= 'table' then return end
  local verified, reason = verify(slot.surface)
  if not verified then
    common.unwrap(slot.records, slot.method)
    slot.unavailable = reason
    return
  end
  slot.unavailable = nil
  common.wrap(slot.records, slot.method, function()
    return current[slot.method]
  end, function(value)
    current[slot.method] = value
  end, function(original)
    return function(...)
      local results = common.pack(original(...))
      if display_enabled(slot, current) and type(results[1]) == 'table' then
        local projected = {}
        for index, item in ipairs(results[1]) do
          if type(item) == 'table' and type(item.value) == 'string'
            and item.value == 'OSC 52 detected, register not checked to maintain compatibility' then
            local copy = common.copy(item)
            copy.value = state.ctx.translate('which-key', 'register_notice', item.value)
            projected[index] = copy
          else
            projected[index] = item
          end
        end
        results[1] = projected
      end
      return unpack(results, 1, results.n)
    end
  end)
end

state.registers_slot = {
  module = 'which-key.plugins.registers', method = 'expand', surface = 'plugin_labels',
  records = state.registers_records,
}

attach_display = function()
  ensure_footer_sources()
  sync_marks()
  sync_registers()
end

local function detach_display()
  for _, slot in ipairs({ state.text_slot, state.plugin_slot, state.registers_slot }) do
    if slot.generation ~= nil then common.unwrap(slot.records, slot.method) end
  end
end

function M.attach(ctx)
  state.ctx = ctx
  if not ctx.enabled() then
    M.detach()
    return
  end

  if not state.source_release then
    state.source_release = ctx.register_source({
      title = 'which-key.nvim',
      domain = 'which-key',
      context = 'notification',
    })
  end
  attach_setup()
  attach_formatter()
  attach_display()
end

function M.detach()
  if state.source_release then
    local release = state.source_release
    state.source_release = nil
    release()
  end
  clear_setup('disabled', true)
  clear_formatter('disabled', true)
  detach_display()
end

local function display_info(slot)
  local current = package.loaded[slot.module]
  if current == nil or current == false then return { active = false, reason = 'not_loaded' } end
  if current ~= slot.generation then return { active = false, reason = 'stale_generation' } end
  if slot.unavailable then return { active = false, reason = slot.unavailable } end
  return {
    active = state.ctx ~= nil and state.ctx.enabled() and common.active(slot.records, slot.method) or false,
    reason = common.reason(slot.records, slot.method),
  }
end

function M.info(ctx)
  local enabled = ctx.enabled()
  local setup_reason = state.setup and common.reason(state.setup.hooks, 'setup')
    or (type(package.loaded['which-key']) == 'table' and 'not_initialized' or 'not_loaded')
  local reason = not enabled and 'disabled'
    or setup_reason == 'external_override' and 'external_override'
    or state.reason or 'not_initialized'
  return {
    active = enabled and state.active == true,
    reason = reason,
    seam = 'replace.desc',
    setup_seam = 'setup',
    setup_active = enabled and state.setup ~= nil and common.active(state.setup.hooks, 'setup'),
    setup_reason = setup_reason,
    notification_seam = 'vim.notify:title',
    notification_active = enabled and state.source_release ~= nil,
    notification = { active = enabled and state.source_release ~= nil },
    preset_descriptions = { active = enabled and state.active == true, reason = reason },
    popup_footer = display_info(state.text_slot),
    marks = display_info(state.plugin_slot),
    registers = display_info(state.registers_slot),
    domain = 'which-key',
    provenance = 'replace.desc has no mapping provenance; identical user descriptions may display built-in translations',
    excluded = 'raw mappings, keys, rhs, register contents, mark paths, spelling suggestions and user data',
  }
end

function M.signature()
  local wk = package.loaded['which-key']
  local config = package.loaded['which-key.config']
  local replace = type(config) == 'table' and config.replace or nil
  local values = {
    tostring(wk),
    tostring(type(wk) == 'table' and wk.setup or nil),
    tostring(config),
    tostring(replace),
    tostring(type(replace) == 'table' and replace.desc or nil),
  }
  for _, slot in ipairs({ state.text_slot, state.plugin_slot, state.registers_slot }) do
    local module = package.loaded[slot.module]
    values[#values + 1] = tostring(module)
    values[#values + 1] = type(module) == 'table' and tostring(module[slot.method]) or 'missing'
  end
  return table.concat(values, ':')
end

return M
