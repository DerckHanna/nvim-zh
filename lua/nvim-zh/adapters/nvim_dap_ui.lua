local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'nvim-dap-ui'
local unpack = table.unpack or unpack

local state = {
  attached = false,
  ctx = nil,
  release_source = nil,
  source_error = nil,
  sync_error = nil,
  setup_ready = false,
  setup_generation = nil,
  canvases = setmetatable({}, { __mode = 'k' }),
}

local slots = {
  setup = { module = 'dapui', method = 'setup', records = {} },
  mapping = { module = 'dapui.util', method = 'apply_mapping', records = {} },
  format_value = { module = 'dapui.util', method = 'format_value', records = {} },
  format_error = { module = 'dapui.util', method = 'format_error', records = {} },
  select_window = { module = 'dapui.util', method = 'select_win', records = {} },
  canvas = { module = 'dapui.render.canvas', method = 'new', surface = 'layouts', records = {} },
  render = { module = 'dapui.render', method = 'new_canvas', surface = 'layouts', records = {} },
  float = { module = 'dapui.windows', method = 'open_float', surface = 'float_title', records = {} },
  select = { module = 'nio.ui', method = 'select', records = {} },
}

local canvas_groups = {
  DapUIBreakpointsInfo = 'breakpoint',
  DapUIWatchesEmpty = 'empty',
  DapUISource = 'source',
}

local select_labels = {
  scopes = 'Scopes',
  breakpoints = 'Breakpoints',
  stacks = 'Stacks',
  watches = 'Watches',
  repl = 'Repl',
  console = 'Console',
}
local select_item_count = 6
local setup_elements = { 'breakpoints', 'repl', 'scopes', 'stacks', 'watches', 'hover', 'console' }

local function translate(context, text)
  if type(text) ~= 'string' or text == '' then return text end
  local ctx = state.ctx
  if not state.attached or not ctx or not ctx.enabled() then return text end
  local ok, translated = pcall(ctx.translate, DOMAIN, context, text)
  if ok and type(translated) == 'string' then return translated end
  return text
end

local function active(slot, generation)
  return state.attached and state.ctx ~= nil and state.ctx.enabled()
    and (not slot.surface or state.ctx.verify(slot.surface) ~= nil)
    and rawequal(package.loaded[slot.module], generation)
    and slot.generation == generation and common.active(slot.records, slot.method)
end

local function setup_complete(generation)
  if state.setup_ready and state.setup_generation == generation then return true end
  -- A late adapter cannot rely on having observed setup. The fixed public API
  -- exposes every built-in element only after successful setup; before setup
  -- this same metatable returns nil for each key. Do not load or inspect buffers.
  if type(generation) ~= 'table' or type(generation.elements) ~= 'table' then return false end
  for _, name in ipairs(setup_elements) do
    if generation.elements[name] == nil then return false end
  end
  return true
end

local restore_canvases
local sync_all

local function project_settings(name, settings, element)
  if type(settings) ~= 'table' or settings.title ~= name then return settings end
  local translated = translate('element_title', settings.title)
  if translated == settings.title then return settings end
  local copy = common.copy(settings)
  copy.title = translated
  if copy.width == nil and type(element) == 'table' and type(element.buffer) == 'function' then
    local buffer = element.buffer()
    if type(buffer) == 'number' and vim.api.nvim_buf_is_valid(buffer) then
      local columns, points = vim.fn.strdisplaywidth(translated), 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
        columns = math.max(columns, vim.fn.strdisplaywidth(line))
        points = math.max(points, vim.str_utfindex(line))
      end
      if columns > points then copy.width = columns end
    end
  end
  return copy
end

local function project_canvas(canvas)
  if type(canvas) ~= 'table' or type(canvas.write) ~= 'function' then return end
  local generation = slots.canvas.generation
  if generation == nil or not common.active(slots.canvas.records, 'new') then return end

  local previous = state.canvases[canvas]
  if previous then
    if canvas.write == previous.wrapper then
      if previous.generation == generation then return end
      canvas.write = previous.own_original
    else
      -- An instance-level replacement is an external override. Never reclaim it.
      previous.active = false
      previous.reason = 'external_override'
      return
    end
  end

  local original = canvas.write
  local own_original = rawget(canvas, 'write')
  local record = {
    generation = generation,
    original = original,
    own_original = own_original,
    active = true,
  }
  local wrapper
  wrapper = function(self, text, opts, ...)
    if not record.active or not state.attached or not state.ctx or not state.ctx.enabled()
      or not active(slots.canvas, record.generation)
      or self.write ~= wrapper then
      return original(self, text, opts, ...)
    end
    if type(text) == 'string' and type(opts) == 'table' then
      local context = canvas_groups[opts.group]
      if context then text = translate(context, text) end
    end
    return original(self, text, opts, ...)
  end
  record.wrapper = wrapper
  state.canvases[canvas] = record
  canvas.write = wrapper
end

restore_canvases = function()
  for canvas, record in pairs(state.canvases) do
    if canvas.write == record.wrapper then canvas.write = record.own_original end
    record.active = false
  end
  state.canvases = setmetatable({}, { __mode = 'k' })
end

local factories = {}

function factories.setup(original, generation)
  local slot = slots.setup
  local wrapper
  wrapper = function(...)
    -- setup() deletes and recreates elements, but does not replace the module
    -- tables wrapped here. Attach leaf render modules only after it has loaded
    -- them through its normal public path; never require an absent plugin.
    local owned = active(slot, generation) and generation.setup == wrapper
    if owned then
      state.setup_ready = false
      state.setup_generation = nil
    end
    local results = common.pack(original(...))
    if owned and active(slot, generation) and generation.setup == wrapper then
      state.setup_ready = true
      state.setup_generation = generation
      local ok, err = pcall(sync_all)
      state.sync_error = not ok and tostring(err) or nil
    end
    return unpack(results, 1, results.n)
  end
  return wrapper
end

function factories.mapping(original, generation)
  local slot = slots.mapping
  return function(mappings, func, buffer, label)
    if active(slot, generation) and type(label) == 'string' then
      label = translate('mapping', label)
    end
    -- At the pinned commit label is used only as nvim_buf_set_keymap desc.
    -- Action IDs, callbacks, keys and action_keys remain untouched.
    return original(mappings, func, buffer, label)
  end
end

function factories.format_value(original, generation)
  local slot = slots.format_value
  return function(value_start, value)
    local results = common.pack(original(value_start, value))
    local lines = results[1]
    if not active(slot, generation) or type(lines) ~= 'table' or type(value) ~= 'string' then
      return unpack(results, 1, results.n)
    end

    local config = package.loaded['dapui.config']
    local max_lines = type(config) == 'table' and type(config.render) == 'table'
      and config.render.max_value_lines or nil
    local line_count = 1
    for _ in value:gmatch('\n') do line_count = line_count + 1 end
    if not max_lines or line_count <= max_lines or #lines == 0 then
      return unpack(results, 1, results.n)
    end

    -- Project only the known final suffix, and only when the pinned formatter
    -- actually truncated this value. No substitution is applied to user data.
    local index = #lines
    local last = lines[index]
    if type(last) == 'string' then
      local prefix, count = last:match('^(.*) %.%.%. %[(%d+) more lines%]$')
      if prefix then
        local suffix = (' ... [%s more lines]'):format(count)
        lines[index] = prefix .. translate('render', suffix)
      end
    end
    return unpack(results, 1, results.n)
  end
end

function factories.format_error(original, generation)
  local slot = slots.format_error
  return function(err)
    local results = common.pack(original(err))
    -- This exact synthetic watches error is the only error formatter result in
    -- the catalog. Arbitrary adapter/DAP messages and formatted bodies pass through.
    if active(slot, generation) and type(err) == 'table' and err.body == nil
      and err.message == 'No active session' and results[1] == 'No active session'
      and next(err) == 'message' and next(err, 'message') == nil then
      results[1] = translate('runtime', results[1])
    end
    return unpack(results, 1, results.n)
  end
end

function factories.select_window(original, generation)
  local slot = slots.select_window
  return function(...)
    local config = package.loaded['dapui.config']
    if not active(slot, generation) or type(config) ~= 'table' or config.select_window ~= nil then
      return original(...)
    end
    local original_print = _G.print
    if type(original_print) ~= 'function' then return original(...) end
    local translated_print
    translated_print = function(...)
      local args = common.pack(...)
      if active(slot, generation) and args[1] == 'Select window: ' then
        args[1] = translate('select_window', args[1])
      end
      return original_print(unpack(args, 1, args.n))
    end
    _G.print = translated_print
    local results = common.pack(pcall(original, ...))
    -- select_win is synchronous. Nested calls form a LIFO chain; an external
    -- replacement made while getchar() blocks remains owned by that caller.
    if _G.print == translated_print then _G.print = original_print end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

local function canvas_factory(slot)
  return function(original, generation)
    return function(...)
      local results = common.pack(original(...))
      if active(slot, generation) then project_canvas(results[1]) end
      return unpack(results, 1, results.n)
    end
  end
end

factories.canvas = canvas_factory(slots.canvas)
factories.render = canvas_factory(slots.render)

function factories.float(original, generation)
  local slot = slots.float
  return function(name, element, position, settings)
    if active(slot, generation) then
      if type(settings) == 'function' then
        local settings_original = settings
        settings = function()
          -- The original resolves function settings at this same point.
          return project_settings(name, settings_original(), element)
        end
      else
        settings = project_settings(name, settings, element)
      end
    end
    -- name remains the float_windows key and close-command identity.
    return original(name, element, position, settings)
  end
end

function factories.select(original, generation)
  local slot = slots.select
  return function(items, args)
    if not active(slot, generation) or not setup_complete(package.loaded.dapui)
      or type(items) ~= 'table' or #items ~= select_item_count
      or type(args) ~= 'table' or args.prompt ~= 'Select an element:'
      or type(args.format_item) ~= 'function' then
      return original(items, args)
    end
    local seen = {}
    for _, item in ipairs(items) do
      if type(item) ~= 'string' or select_labels[item] == nil or seen[item] then
        return original(items, args)
      end
      seen[item] = true
    end

    -- nio.ui is shared. These checks deliberately exclude a same-prompt call
    -- before dapui setup, lists with custom/foreign items, and other formatters.
    local copy = common.copy(args)
    copy.prompt = translate('select', args.prompt)
    local format_item = args.format_item
    copy.format_item = function(item)
      local text = format_item(item)
      if type(item) == 'string' and text == select_labels[item] then
        return translate('select_item', text)
      end
      return text
    end
    return original(items, copy)
  end
end

local function sync(slot)
  local current = package.loaded[slot.module]
  if current ~= slot.generation then
    if slot.generation ~= nil then
      -- Invalidate retained closures before restoring the old generation.
      slot.generation = nil
      if slot == slots.setup then
        state.setup_ready = false
        state.setup_generation = nil
      end
      if slot == slots.canvas then restore_canvases() end
      common.unwrap(slot.records, slot.method)
    end
    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then
      if current ~= nil and current ~= false then
        slot.records[slot.method] = { active = false, reason = 'unsupported_api' }
      end
      return
    end
  end
  if type(current) ~= 'table' then return end
  if slot.surface then
    local verified, reason = state.ctx.verify(slot.surface)
    if not verified then
      if slot == slots.canvas then restore_canvases() end
      common.unwrap(slot.records, slot.method)
      slot.unavailable = reason
      return
    end
    slot.unavailable = nil
  end
  common.wrap(slot.records, slot.method,
    function() return current[slot.method] end,
    function(value) current[slot.method] = value end,
    function(original) return slot.factory(original, current) end)
end

sync_all = function()
  -- setup first owns the lifecycle; canvas precedes render because render/init
  -- snapshots canvas.new as new_canvas at module load time.
  sync(slots.setup)
  sync(slots.mapping)
  sync(slots.format_value)
  sync(slots.format_error)
  sync(slots.select_window)
  sync(slots.canvas)
  sync(slots.render)
  sync(slots.float)
  sync(slots.select)
end

for name, slot in pairs(slots) do slot.factory = factories[name] end

local function register_source()
  if state.release_source or state.source_error then return end
  local ok, release = pcall(state.ctx.register_source, {
    title = 'nvim-dap-ui',
    domain = DOMAIN,
    context = 'notification',
  })
  if ok then
    state.release_source = release
  else
    state.source_error = tostring(release)
  end
end

function M.attach(ctx)
  state.ctx = ctx
  state.attached = ctx.enabled()
  if not state.attached then return M.detach() end
  register_source()
  sync_all()
end

function M.detach()
  state.attached = false
  state.setup_ready = false
  state.setup_generation = nil
  if state.release_source then
    local release = state.release_source
    state.release_source = nil
    release()
  end
  state.source_error = nil
  restore_canvases()
  for _, slot in pairs(slots) do
    if slot.generation ~= nil then common.unwrap(slot.records, slot.method) end
  end
end

local function seam_info(slot)
  local current = package.loaded[slot.module]
  if current == nil or current == false then return { active = false, reason = 'not_loaded' } end
  if current ~= slot.generation then return { active = false, reason = 'stale_generation' } end
  if slot.unavailable then return { active = false, reason = slot.unavailable } end
  return {
    active = state.attached and common.active(slot.records, slot.method) or false,
    reason = common.reason(slot.records, slot.method),
  }
end

function M.info(ctx)
  local info = {}
  local display_active, lifecycle_active, any_override, any_loaded = false, false, false, false
  for name, slot in pairs(slots) do
    local current = seam_info(slot)
    info[name] = current
    if name == 'setup' then
      lifecycle_active = lifecycle_active or current.active
    else
      display_active = display_active or current.active
    end
    any_override = any_override or current.reason == 'external_override'
    any_loaded = any_loaded or package.loaded[slot.module] ~= nil
  end
  local enabled = state.attached and ctx.enabled()
  local reason
  if not enabled then
    reason = 'disabled'
  elseif not package.loaded['dapui'] then
    reason = 'not_loaded'
  elseif any_override then
    reason = 'external_override'
  elseif state.sync_error then
    reason = 'sync_failed'
  elseif display_active then
    reason = 'attached'
  elseif lifecycle_active then
    reason = 'waiting_for_setup'
  else
    reason = any_loaded and 'partially_active' or 'not_loaded'
  end
  return {
    active = enabled and display_active or false,
    lifecycle_active = enabled and lifecycle_active or false,
    reason = reason,
    seam = 'Canvas.new/write(highlight-scoped); util.apply_mapping(desc); util.format_value/error; util.select_win(scoped exact print); windows.open_float(title); nio.ui.select; setup lifecycle; exact vim.notify title',
    domain = DOMAIN,
    notification = {
      active = state.release_source ~= nil,
      error = state.source_error,
      title = 'nvim-dap-ui',
      context = 'notification',
    },
    setup = info.setup,
    canvas = info.canvas,
    render = info.render,
    mapping = info.mapping,
    format_value = info.format_value,
    format_error = info.format_error,
    select_window = info.select_window,
    float = info.float,
    select = info.select,
    select_guard = 'shared nio.ui only after dapui setup; exactly six built-in non-hover IDs and expected formatter labels',
    sync_error = state.sync_error,
    existing_buffers = 'not_scanned; newly rendered canvases only',
    buffer_names = 'preserved: names are lookup identity, not display-only titles',
    select_window_guard = 'default path only; synchronous exact print projection with reentrant/error restoration; custom select_window provider untouched',
    internal_errors = 'preserved: dependency/registration/layout/DAP error values',
    controls = 'icons only at pinned commit; no fixed hover text',
    dynamic_data = 'preserved: scopes, variables, values, expressions, frames, threads, paths, debugger output and protocol IDs',
  }
end

function M.signature()
  local values = {}
  for _, name in ipairs({ 'setup', 'mapping', 'format_value', 'format_error', 'select_window', 'canvas', 'render', 'float', 'select' }) do
    local slot = slots[name]
    local module = package.loaded[slot.module]
    values[#values + 1] = slot.module
    values[#values + 1] = tostring(module)
    values[#values + 1] = type(module) == 'table' and tostring(module[slot.method]) or 'missing'
  end
  return table.concat(values, ':')
end

return M
