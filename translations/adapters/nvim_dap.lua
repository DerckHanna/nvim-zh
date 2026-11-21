local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'nvim-dap'
local uv = vim.uv
local unpack = table.unpack or unpack
local attached = false
local ctx
local release_notification
local main = {}
local repl_calls = setmetatable({}, { __mode = 'k' })
local function resolve_owner(slot, module)
  if type(module) ~= 'table' then return nil end
  if slot.owner then return slot.owner(module) end
  return module
end

-- Version-related seams additionally require loading evidence for the pinned
-- sources. A caller that supplies no verify() (a stub context) therefore keeps
-- the English text rather than translating on an unproven revision.
local function verify(surface)
  if surface == nil then return { kind = 'api_contract' } end
  if type(ctx) ~= 'table' or type(ctx.verify) ~= 'function' then return nil, 'unsupported_api' end
  local result, reason = ctx.verify(surface)
  if result == nil then return nil, reason or 'unsupported_api' end
  return result
end

local function enabled(slot, generation)
  return attached and ctx and ctx.enabled() and slot.generation == generation
    and rawequal(resolve_owner(slot, package.loaded[slot.module]), generation)
    and common.active(slot.records, slot.method)
    and verify(slot.surface) ~= nil
end

local function translate(context, text)
  return ctx.translate(DOMAIN, context, text)
end

local factories = {}
local slots = {
  pick_one = { module = 'dap.ui', method = 'pick_one', records = {} },
  pick_one_sync = { module = 'dap.ui', method = 'pick_one_sync', records = {} },
  repl_execute = { module = 'dap.repl', method = 'execute', records = {} },
  repl_append = { module = 'dap.repl', method = 'append', records = {} },
  repl_open = { module = 'dap.repl', method = 'open', records = {} },
  repl_toggle = { module = 'dap.repl', method = 'toggle', records = {} },
  repl_frames = { module = 'dap.repl', method = 'print_stackframes', records = {} },
  quickfix = { module = 'dap.breakpoints', method = 'to_qf_list', records = {} },
  health = { module = 'dap.health', method = 'check', records = {} },
  exception_input = { module = 'dap.session', method = 'set_exception_breakpoints', records = {} },
  variable_actions = {
    module = 'dap.entity',
    method = 'compute_actions',
    records = {},
    owner = function(module)
      return type(module.variable) == 'table' and module.variable.tree_spec or nil
    end,
  },
  thread_root = {
    module = 'dap.entity',
    method = 'render_parent',
    records = {},
    owner = function(module)
      return type(module.threads) == 'table' and module.threads.tree_spec or nil
    end,
  },
  -- Version-related surfaces below. Each is gated by ctx.verify() on the pinned
  -- source digests; without loading evidence the original text renders.
  widgets_builder = {
    module = 'dap.ui.widgets',
    method = 'builder',
    records = {},
    surface = 'widgets',
  },
  exception_info = {
    module = 'dap.session',
    method = '_show_exception_info',
    records = {},
    surface = 'diagnostics',
  },
  spawn = {
    module = 'dap.session',
    method = 'spawn',
    records = {},
    surface = 'notifications',
  },
  connect = {
    module = 'dap.session',
    method = 'connect',
    records = {},
    surface = 'notifications',
  },
  to_dict = {
    module = 'dap.utils',
    method = 'to_dict',
    records = {},
    surface = 'notifications',
  },
  load_launchjs = {
    module = 'dap.ext.vscode',
    method = 'load_launchjs',
    records = {},
    surface = 'notifications',
  },
}

local function project_label(key, generation, label_fn)
  if type(label_fn) ~= 'function' then return label_fn end
  return function(item)
    local text = label_fn(item)
    if not enabled(slots[key], generation) or type(item) ~= 'table' then return text end
    -- These structural tags distinguish plugin-owned actions/process labels from
    -- configuration names, file paths, DAP targets, frames and thread names.
    if type(item.fn) == 'function' or type(item.action) == 'function' then
      return translate('action', text)
    end
    if type(item.pid) == 'number' and type(item.name) == 'string' then
      return translate('process', text)
    end
    return text
  end
end

local function pick_factory(key, original, generation)
  return function(items, prompt, label_fn, ...)
    if not enabled(slots[key], generation) then
      return original(items, prompt, label_fn, ...)
    end
    return original(items, translate('prompt', prompt), project_label(key, generation, label_fn), ...)
  end
end

factories.pick_one = function(original, generation)
  return pick_factory('pick_one', original, generation)
end
factories.pick_one_sync = function(original, generation)
  return pick_factory('pick_one_sync', original, generation)
end

local function is_help_command(text)
  local repl = package.loaded['dap.repl']
  local commands = type(repl) == 'table' and repl.commands or nil
  local help = type(commands) == 'table' and commands.help or nil
  if type(help) ~= 'table' then return false end
  for _, command in ipairs(help) do
    if text == command then return true end
  end
  return false
end

local function running()
  return coroutine.running() or main
end

local function session()
  local dap = package.loaded.dap
  return dap and type(dap.session) == 'function' and dap.session() or nil
end

-- A suspended REPL command cannot authorize another coroutine's output.
local function with_repl_call(kind, fn, ...)
  local thread, calls = running(), repl_calls
  local parent = calls[thread]
  calls[thread] = { kind = kind, session = session() }
  local results = common.pack(pcall(fn, ...))
  calls[thread] = parent
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local function with_help(fn, text, ...)
  return with_repl_call(is_help_command(text) and 'repl_help' or nil, fn, text, ...)
end

-- new_buf() is private. These three public entry points are the fixed paths that
-- can create it. Scoped hooks cover both the public execute('.help') path and
-- the local callback used when a user types .help in a newly-created prompt.
local function with_repl_buffer_hooks(slot, generation, fn, ...)
  if not enabled(slot, generation) then return fn(...) end
  local original_keymap_set = vim.keymap.set
  local original_prompt_setcallback = vim.fn.prompt_setcallback
  local thread = running()
  local keymap_wrapper, prompt_wrapper

  if type(original_keymap_set) == 'function' then
    keymap_wrapper = function(mode, lhs, rhs, opts)
      if running() ~= thread or not enabled(slot, generation) or type(opts) ~= 'table' or type(opts.desc) ~= 'string' then
        return original_keymap_set(mode, lhs, rhs, opts)
      end
      local translated = translate('mapping', opts.desc)
      if translated == opts.desc then return original_keymap_set(mode, lhs, rhs, opts) end
      local copy = common.copy(opts)
      copy.desc = translated
      return original_keymap_set(mode, lhs, rhs, copy)
    end
    vim.keymap.set = keymap_wrapper
  end

  if type(original_prompt_setcallback) == 'function' then
    prompt_wrapper = function(buf, callback)
      if running() ~= thread or not enabled(slot, generation) or type(callback) ~= 'function' then
        return original_prompt_setcallback(buf, callback)
      end
      return original_prompt_setcallback(buf, function(text)
        if not enabled(slot, generation) then return callback(text) end
        return with_help(callback, text)
      end)
    end
    vim.fn.prompt_setcallback = prompt_wrapper
  end

  local results = common.pack(pcall(fn, ...))
  if keymap_wrapper and vim.keymap.set == keymap_wrapper then
    vim.keymap.set = original_keymap_set
  end
  if prompt_wrapper and vim.fn.prompt_setcallback == prompt_wrapper then
    vim.fn.prompt_setcallback = original_prompt_setcallback
  end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- vim.fn.input is synchronous in all three fixed call sites. Scope the display
-- projection to the original call, restore on every exit path, and make retained
-- callbacks inert after detach or an owner-generation change.
local function with_input_prompt(slot, generation, fn, ...)
  if not enabled(slot, generation) or type(vim.fn.input) ~= 'function' then return fn(...) end
  local original_input = vim.fn.input
  local thread = running()
  local wrapper
  wrapper = function(prompt, ...)
    if running() ~= thread or not enabled(slot, generation) then return original_input(prompt, ...) end
    return original_input(translate('prompt', prompt), ...)
  end
  vim.fn.input = wrapper
  local results = common.pack(pcall(fn, ...))
  if vim.fn.input == wrapper then vim.fn.input = original_input end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

factories.repl_execute = function(original, generation)
  return function(text, ...)
    local function call(input, ...)
      return with_help(original, input, ...)
    end
    return with_repl_buffer_hooks(slots.repl_execute, generation, call, text, ...)
  end
end

factories.repl_append = function(original, generation)
  return function(line, ...)
    if not enabled(slots.repl_append, generation) then return original(line, ...) end
    local invocation = repl_calls[running()]
    local caller = debug.getinfo(2, 'Sl')
    local upstream = debug.getinfo(original, 'S').source
    local function call(input, ...)
      if caller and caller.source == upstream then
        if caller.currentline == 299 and input == 'No active debug session' and not session() then
          input = translate('repl_message', input)
        elseif invocation and invocation.kind and rawequal(invocation.session, session()) then
          input = translate(invocation.kind, input)
        end
      end
      return original(input, ...)
    end
    return with_repl_buffer_hooks(slots.repl_append, generation, call, line, ...)
  end
end

factories.repl_open = function(original, generation)
  return function(...)
    return with_repl_buffer_hooks(slots.repl_open, generation, original, ...)
  end
end

factories.repl_toggle = function(original, generation)
  return function(...)
    return with_repl_buffer_hooks(slots.repl_toggle, generation, original, ...)
  end
end

factories.repl_frames = function(original, generation)
  return function(...)
    if not enabled(slots.repl_frames, generation) then return original(...) end
    return with_repl_call('repl_hint', original, ...)
  end
end

local function non_empty(value)
  if type(value) == 'table' then return next(value) ~= nil end
  return value and #value > 0 or false
end

local function quickfix_text(bp, bufnr, lnum)
  local state = bp.state or {}
  local source_lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
  local parts = { unpack(source_lines, 1) }
  if state.verified == false then
    if state.message then
      parts[#parts + 1] = translate('quickfix', 'Rejected: ' .. state.message)
    else
      parts[#parts + 1] = translate('quickfix', 'Rejected')
    end
  end
  if non_empty(bp.logMessage) then
    parts[#parts + 1] = translate('quickfix', 'Log message: ' .. bp.logMessage)
  end
  if non_empty(bp.condition) then
    parts[#parts + 1] = translate('quickfix', 'Condition: ' .. bp.condition)
  end
  if non_empty(bp.hitCondition) then
    parts[#parts + 1] = translate('quickfix', 'Hit condition: ' .. bp.hitCondition)
  end
  return table.concat(parts, ', ')
end

factories.quickfix = function(original, generation)
  return function(breakpoints, ...)
    local result = original(breakpoints, ...)
    if not enabled(slots.quickfix, generation)
      or type(result) ~= 'table' or type(breakpoints) ~= 'table' then
      return result
    end
    local by_location = {}
    for bufnr, buf_breakpoints in pairs(breakpoints) do
      if type(buf_breakpoints) == 'table' then
        for _, bp in pairs(buf_breakpoints) do
          if type(bp) == 'table' and type(bp.line) == 'number' then
            local key = tostring(bufnr) .. ':' .. bp.line
            if by_location[key] then
              by_location[key].ambiguous = true
            else
              by_location[key] = { bp = bp }
            end
          end
        end
      end
    end
    local projected = {}
    for index, item in ipairs(result) do
      local copy = type(item) == 'table' and common.copy(item) or item
      if type(copy) == 'table' then
        local location = by_location[tostring(copy.bufnr) .. ':' .. tostring(copy.lnum)]
        if location and not location.ambiguous then
          copy.text = quickfix_text(location.bp, copy.bufnr, copy.lnum)
        end
      end
      projected[index] = copy
    end
    return projected
  end
end

factories.exception_input = function(original, generation)
  return function(...)
    return with_input_prompt(slots.exception_input, generation, original, ...)
  end
end

factories.variable_actions = function(original, generation)
  return function(...)
    local returns = common.pack(original(...))
    local actions = returns[1]
    if not enabled(slots.variable_actions, generation) or type(actions) ~= 'table' then
      return unpack(returns, 1, returns.n)
    end
    local projected = {}
    for index, action in ipairs(actions) do
      if type(action) == 'table' and (action.label == 'Set variable' or action.label == 'Set expression')
        and type(action.fn) == 'function' then
        local copy = common.copy(action)
        local original_fn = action.fn
        copy.fn = function(...)
          return with_input_prompt(slots.variable_actions, generation, original_fn, ...)
        end
        projected[index] = copy
      else
        projected[index] = action
      end
    end
    returns[1] = projected
    return unpack(returns, 1, returns.n)
  end
end

factories.health = function(original, generation)
  return function(...)
    if not enabled(slots.health, generation) or type(vim.health) ~= 'table' then
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
end

-- dap.lua:316-323 reports a launch.json read failure straight from the public
-- module through vim.notify_once. Upstream concatenates the caught error onto a
-- literal "%s" template, so the rendered message is
-- "Can't get configurations from launch.json:\n%s" followed by the diagnostic:
-- the rendered text can never match a catalog template. The provider registered
-- in dap.providers.configs owns that branch, so wrapping that one entry reaches
-- the real call site; only the fixed prefix is projected and the diagnostic
-- payload is re-attached unchanged. The seam is a vim.notify wrapper that is
-- active only while the real provider call runs, so no other plugin or debugger
-- notification is touched.
local LAUNCH_PREFIX = "Can't get configurations from launch.json:"
local LAUNCH_SEPARATOR = '\n%s'
local LAUNCH_MSGID = "Can't get configurations from launch.json:\n%s"
local LAUNCH_PROVIDER = 'dap.launch.json'
local launch_record

local function project_launch(msg, previous, level, opts)
  if type(msg) ~= 'string' or msg:sub(1, #LAUNCH_PREFIX) ~= LAUNCH_PREFIX then
    return previous(msg, level, opts)
  end
  local rest = msg:sub(#LAUNCH_PREFIX + 1)
  -- Upstream leaves the template's literal "%s" between the prefix and the
  -- payload ("...launch.json:\n%s" .. err); drop that exact separator once.
  local payload
  if rest:sub(1, #LAUNCH_SEPARATOR) == LAUNCH_SEPARATOR then
    payload = rest:sub(#LAUNCH_SEPARATOR + 1)
  else
    payload = rest
  end
  local translated = translate('notification', LAUNCH_PREFIX .. LAUNCH_SEPARATOR)
  if translated == LAUNCH_PREFIX .. LAUNCH_SEPARATOR then
    return previous(msg, level, opts)
  end
  -- The entry translates the prefix and keeps the separator slot; replace
  -- that slot with the untouched payload.
  local head = translated
  if head:sub(-#LAUNCH_SEPARATOR) == LAUNCH_SEPARATOR then
    head = head:sub(1, #head - #LAUNCH_SEPARATOR)
  end
  return previous(head .. payload, level, opts)
end

local function install_launch_provider()
  local dap = package.loaded['dap']
  if not attached or type(dap) ~= 'table' or type(dap.providers) ~= 'table'
    or type(dap.providers.configs) ~= 'table' then
    return
  end
  local configs = dap.providers.configs
  if launch_record then
    if configs[LAUNCH_PROVIDER] ~= launch_record.wrapper then launch_record = nil else return end
  end
  local original = configs[LAUNCH_PROVIDER]
  if type(original) ~= 'function' then return end
  local wrapper
  wrapper = function(...)
    if not attached or not ctx or not ctx.enabled() or configs[LAUNCH_PROVIDER] ~= wrapper then
      return original(...)
    end
    local previous = vim.notify
    local projected
    if type(previous) == 'function' then
      projected = function(msg, level, opts) return project_launch(msg, previous, level, opts) end
      vim.notify = projected
    end
    local results = common.pack(pcall(original, ...))
    if projected and vim.notify == projected then vim.notify = previous end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
  configs[LAUNCH_PROVIDER] = wrapper
  launch_record = { wrapper = wrapper, original = original }
end

local function restore_launch_provider()
  local dap = package.loaded['dap']
  if launch_record and type(dap) == 'table' and type(dap.providers) == 'table'
    and type(dap.providers.configs) == 'table'
    and dap.providers.configs[LAUNCH_PROVIDER] == launch_record.wrapper then
    dap.providers.configs[LAUNCH_PROVIDER] = launch_record.original
  end
  launch_record = nil
end

-- ---------------------------------------------------------------------------
-- Scoped display proxies. Each helper installs one display function for the
-- duration of an owned call, restores it on every exit path (including a raised
-- error), and only reclaims the value it still owns. A retained closure stays
-- inert after detach or an owner-generation change.
-- ---------------------------------------------------------------------------

-- vim.notify scoped to one call. Only strings accepted by `project` change;
-- everything else is forwarded byte-identically with the original arguments.
local function with_notify(generation, slot, project, fn, ...)
  if not enabled(slot, generation) or type(vim.notify) ~= 'function' then return fn(...) end
  local previous = vim.notify
  local thread = running()
  local wrapper
  wrapper = function(message, ...)
    if running() ~= thread or not enabled(slot, generation) then return previous(message, ...) end
    local translated = project(message)
    if translated == nil then return previous(message, ...) end
    return previous(translated, ...)
  end
  vim.notify = wrapper
  local results = common.pack(pcall(fn, ...))
  if vim.notify == wrapper then vim.notify = previous end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- vim.notify_once scoped to one call. The dedup key stays a constant string for
-- the one fixed msgid it projects, so the plugin's own once-only semantics are
-- preserved; every other message is forwarded untouched.
local function with_notify_once(generation, slot, msgid, fn, ...)
  if not enabled(slot, generation) or type(vim.notify_once) ~= 'function' then return fn(...) end
  local previous = vim.notify_once
  local thread = running()
  local wrapper
  wrapper = function(message, ...)
    if running() ~= thread or not enabled(slot, generation) or type(message) ~= 'string' or message ~= msgid then
      return previous(message, ...)
    end
    return previous(translate('deprecation', msgid), ...)
  end
  vim.notify_once = wrapper
  local results = common.pack(pcall(fn, ...))
  if vim.notify_once == wrapper then vim.notify_once = previous end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- ---------------------------------------------------------------------------
-- (1) dap.ui.widgets fixed messages.
--
-- lua/dap/ui/widgets.lua renders seven fixed messages through the generic
-- ui.layer.render path (207, 251, 255, 261, 271, 402 and 423). That same layer
-- carries debugger data (frames, scopes, variables) and user expressions, so
-- projection is restricted on three independent axes:
--   * the builder was created for one of the plugin's own widget tables
--     (module.threads/frames/expression/scopes/sessions by identity),
--   * the layer.render CALL SITE is one of the seven pinned lines inside the
--     loaded lua/dap/ui/widgets.lua (resolved through debug.getinfo and the
--     runtime file realpath, so dap.async.run renders attribute correctly),
--   * the argument shape matches that call site exactly (one string for the six
--     single-message sites, {msg, "", tostring(err)} for the evaluate failure).
-- Only xs[1] is ever projected, and only through the widget catalog context, so
-- an unrecognised message and every debugger value stay verbatim.
local WIDGET_FILE = 'lua/dap/ui/widgets.lua'
local WIDGET_SINGLE_SITES = { [207] = true, [251] = true, [255] = true, [261] = true,
  [271] = true, [402] = true }
local WIDGET_EVALUATE_SITE = 423
local WIDGET_SITES = vim.tbl_extend('force', { [WIDGET_EVALUATE_SITE] = true }, WIDGET_SINGLE_SITES)
local widget_views = setmetatable({}, { __mode = 'k' })
local widget_builders = setmetatable({}, { __mode = 'k' })

-- Resolve the pinned upstream file to its real path once. A module can only be
-- attributed to a pinned file when the resolved path matches the file the
-- runtime would load, so a same-named file elsewhere never matches.
local runtime_paths = {}
local function runtime_path(relative)
  local cached = runtime_paths[relative]
  if cached == nil then
    local file = vim.api.nvim_get_runtime_file(relative, false)[1]
    cached = file and uv.fs_realpath(file) or false
    runtime_paths[relative] = cached
  end
  return cached or nil
end

-- The first stack frame inside a pinned file at one of `hits` (a set of line
-- numbers), or nil. Walking the stack makes the projection depend on the real
-- call site instead of on the argument shape alone, which is what keeps the
-- shared render paths and debugger payloads out of scope.
local function stack_line(relative, hits)
  local target = runtime_path(relative)
  if not target then return nil end
  local suffix = '/' .. relative
  for level = 3, 14 do
    local info = debug.getinfo(level, 'Sl')
    if not info then return nil end
    local source, line = info.source, info.currentline
    if type(source) == 'string' and type(line) == 'number' and hits[line]
      and source:sub(1, 1) == '@' and source:sub(-#suffix) == suffix
      and uv.fs_realpath(source:sub(2)) == target then
      return line
    end
  end
  return nil
end

local function project_widget_items(site, items)
  if type(items) ~= 'table' or type(items[1]) ~= 'string' then return nil end
  if WIDGET_SINGLE_SITES[site] then
    if #items ~= 1 then return nil end
  elseif site == WIDGET_EVALUATE_SITE then
    -- Upstream renders {msg, "", tostring(err)}; the empty separator and the
    -- adapter error payload are part of the pinned shape.
    if #items ~= 3 or items[2] ~= '' then return nil end
  else
    return nil
  end
  local translated = translate('widget', items[1])
  if translated == items[1] then return nil end
  local copy = {}
  for index, value in ipairs(items) do copy[index] = value end
  copy[1] = translated
  return copy
end

local function widgets_owned(module, widget)
  if type(module) ~= 'table' or type(widget) ~= 'table' then return false end
  for _, name in ipairs({ 'threads', 'frames', 'expression', 'scopes', 'sessions' }) do
    if rawequal(module[name], widget) then return true end
  end
  return false
end

local function project_view(view, generation)
  local record = widget_views[view]
  if record then
    -- Still ours: reuse. Replaced by someone else: theirs, never reclaimed.
    return view
  end
  if type(view) ~= 'table' or type(view.layer) ~= 'function' then return view end
  record = { original = view.layer, generation = generation, layers = setmetatable({}, { __mode = 'k' }) }
  local wrapper
  wrapper = function(...)
    local layer = record.original(...)
    if type(layer) ~= 'table' or type(layer.render) ~= 'function' then return layer end
    local proxy = record.layers[layer]
    if proxy then return proxy end
    -- A layer proxy, mirroring upstream's own resizing_layer shape. The real
    -- render is looked up on every call so a later upstream replacement (the
    -- resize decoration is re-applied per view.layer() call) stays in effect.
    proxy = setmetatable({}, { __index = layer })
    proxy.render = function(items, render_fn, ...)
      if not enabled(slots.widgets_builder, generation) then
        return layer.render(items, render_fn, ...)
      end
      local site = stack_line(WIDGET_FILE, WIDGET_SITES)
      local projected = site and project_widget_items(site, items) or nil
      if not projected then return layer.render(items, render_fn, ...) end
      return layer.render(projected, render_fn, ...)
    end
    record.layers[layer] = proxy
    return proxy
  end
  record.wrapper = wrapper
  view.layer = wrapper
  widget_views[view] = record
  return view
end

factories.widgets_builder = function(original, generation)
  return function(widget, ...)
    local builder = original(widget, ...)
    local module = package.loaded['dap.ui.widgets']
    if not widgets_owned(module, widget) or type(builder) ~= 'table'
      or type(builder.build) ~= 'function' then
      return builder
    end
    local record = widget_builders[builder]
    if record and builder.build == record.wrapper then return builder end
    local original_build = builder.build
    local wrapper
    wrapper = function(...)
      local view = original_build(...)
      if not enabled(slots.widgets_builder, generation) then return view end
      return project_view(view, generation)
    end
    builder.build = wrapper
    widget_builders[builder] = { original = original_build, wrapper = wrapper }
    return builder
  end
end

-- ---------------------------------------------------------------------------
-- (2) Exception diagnostics (lua/dap/session.lua:344-385).
--
-- Session:_show_exception_info is the sole producer of the 'nvim-dap' sourced
-- diagnostic, so wrapping that one method owns the branch. Upstream yields
-- inside self:request('exceptionInfo', ...) before building the message, so the
-- scoped vim.diagnostic.set proxy stays installed across the suspension; the
-- coroutine identity captured at entry keeps diagnostics emitted meanwhile by
-- unrelated code untouched. The message is split on newlines and each line is
-- translated independently, so no template can capture a following line, and
-- the exception type, break mode, description, stack trace and vim.inspect'd
-- inner exceptions stay byte-identical.
local SESSION_FILE = 'lua/dap/session.lua'
-- The vim.diagnostic.set call at session.lua:373 and the msg_parts insertions
-- at 358/360/364/368 all belong to _show_exception_info; the table constructor
-- spans 373-384, so the frame reports the statement line 373.
local DIAGNOSTIC_SITES = { [358] = true, [360] = true, [364] = true, [368] = true, [373] = true }

local function project_diagnostic_message(message)
  local lines = vim.split(message, '\n', { plain = true })
  local changed = false
  for index, line in ipairs(lines) do
    local translated = translate('diagnostic', line)
    if translated ~= line then
      lines[index] = translated
      changed = true
    end
  end
  return changed and table.concat(lines, '\n') or nil
end

local function project_diagnostics(co, items)
  if coroutine.running() ~= co then return nil end
  if type(items) ~= 'table' or #items ~= 1 then return nil end
  local item = items[1]
  if type(item) ~= 'table' or item.source ~= 'nvim-dap' or type(item.message) ~= 'string' then
    return nil
  end
  if not stack_line(SESSION_FILE, DIAGNOSTIC_SITES) then return nil end
  local message = project_diagnostic_message(item.message)
  if not message then return nil end
  -- Copy the fixed-shape diagnostic list and the one changed field; every other
  -- diagnostic field (position, severity, source) is shared unchanged.
  local copied = common.copy(item)
  copied.message = message
  return { copied }
end

factories.exception_info = function(original, generation)
  return function(self, ...)
    if not enabled(slots.exception_info, generation) or type(vim.diagnostic) ~= 'table'
      or type(vim.diagnostic.set) ~= 'function' then
      return original(self, ...)
    end
    local previous = vim.diagnostic.set
    local co = coroutine.running()
    local wrapper
    wrapper = function(ns, bufnr, items, ...)
      if not enabled(slots.exception_info, generation) then
        return previous(ns, bufnr, items, ...)
      end
      local projected = project_diagnostics(co, items)
      if not projected then return previous(ns, bufnr, items, ...) end
      return previous(ns, bufnr, projected, ...)
    end
    vim.diagnostic.set = wrapper
    local results = common.pack(pcall(original, self, ...))
    if vim.diagnostic.set == wrapper then vim.diagnostic.set = previous end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

-- ---------------------------------------------------------------------------
-- (3) lua/dap/session.lua:1621-1630 — Session.spawn's bare vim.notify.
--
-- The failing branch is synchronous: uv.spawn returns no handle, the pipes are
-- closed and vim.notify(msg, ERROR) runs before Session.spawn returns, so a
-- scoped proxy needs no suspension handling here. The three spawn-error
-- templates are already in the catalog for the utils.notify path
-- (lua/dap/session.lua:1358); only strings carrying one of those fixed prefixes
-- are projected and every other notification passes through verbatim.
local SPAWN_PREFIXES = { 'Executable `', '`command` of adapter `', 'Error running `' }

local function project_spawn_message(message)
  if type(message) ~= 'string' then return nil end
  local candidate = false
  for _, prefix in ipairs(SPAWN_PREFIXES) do
    if message:sub(1, #prefix) == prefix then
      candidate = true
      break
    end
  end
  if not candidate then return nil end
  local translated = translate('notification', message)
  if translated == message then return nil end
  return translated
end

factories.spawn = function(original, generation)
  return function(...)
    if not enabled(slots.spawn, generation) then return original(...) end
    return with_notify(generation, slots.spawn, project_spawn_message, original, ...)
  end
end

-- ---------------------------------------------------------------------------
-- (4) Deprecated public APIs.
--
-- Both use a bare vim.notify_once with one exact fixed string and no title, so
-- the public module function is the only provable owner. Each wrapper scopes a
-- vim.notify_once proxy to its own call and translates only that msgid; the
-- dedup key remains a single constant string, so the upstream once-only
-- behaviour and every unrelated notification are unchanged.
local TO_DICT_MSGID = 'dap.utils.to_dict is deprecated for removal in nvim-dap 0.10.0'
local LOAD_LAUNCHJS_MSGID = 'dap.ext.vscode.load_launchjs is deprecated as it is no longer needed.'
  .. ' ./.vscode/launch.json files are read automatically on-demand. See :help dap-providers'

factories.to_dict = function(original, generation)
  return function(...)
    if not enabled(slots.to_dict, generation) then return original(...) end
    return with_notify_once(generation, slots.to_dict, TO_DICT_MSGID, original, ...)
  end
end

factories.load_launchjs = function(original, generation)
  return function(...)
    if not enabled(slots.load_launchjs, generation) then return original(...) end
    return with_notify_once(generation, slots.load_launchjs, LOAD_LAUNCHJS_MSGID, original, ...)
  end
end

-- ---------------------------------------------------------------------------
-- (6) lua/dap/session.lua:1486 — 'Could not resolve %s'.
--
-- Session.connect is public and builds that message inside its on_addresses
-- closure before calling the caller's on_connect callback. Wrapping the callback
-- argument keeps argument identity and count while projecting only a first
-- argument that matches the exact session-context template; libuv connect
-- errors and every other err value pass through byte-identically. No outer
-- template is added, so the already-translated
-- "Couldn't connect to %s:%s: %s" notification stays unambiguous.
factories.connect = function(original, generation)
  return function(adapter, config, opts, on_connect, ...)
    if not enabled(slots.connect, generation) or type(on_connect) ~= 'function' then
      return original(adapter, config, opts, on_connect, ...)
    end
    local wrapper
    wrapper = function(err, ...)
      if enabled(slots.connect, generation) and type(err) == 'string' then
        local translated = translate('session', err)
        if translated ~= err then err = translated end
      end
      return on_connect(err, ...)
    end
    return original(adapter, config, opts, wrapper, ...)
  end
end

factories.thread_root = function(original, generation)
  return function(thread, ...)
    local returns = common.pack(original(thread, ...))
    if enabled(slots.thread_root, generation) and type(thread) == 'table'
      and thread.id == 0 and type(thread.threads) == 'table' and thread.name == 'Threads' then
      returns[1] = translate('widget', returns[1])
    end
    return unpack(returns, 1, returns.n)
  end
end

-- The resolved pinned paths are re-read after every detach: a plugin update can
-- move the loaded file, and a cached path would then attribute frames to a tree
-- that is no longer loaded.
local function clear_runtime_paths()
  for key in pairs(runtime_paths) do runtime_paths[key] = nil end
end

local function sync(slot)
  local module = package.loaded[slot.module]
  local current = type(module) == 'table' and resolve_owner(slot, module) or nil
  if current ~= slot.generation then
    if slot.generation ~= nil then
      local previous = slot.generation
      slot.generation = nil -- invalidate closures retained by other modules
      common.unwrap(slot.records, slot.method)
      slot.generation = previous
    end
    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then
      if current ~= nil then slot.records[slot.method] = { active = false, reason = 'unsupported_api' } end
      return
    end
  end
  if type(current) ~= 'table' then return end
  common.wrap(slot.records, slot.method,
    function() return current[slot.method] end,
    function(value) current[slot.method] = value end,
    function(original) return factories[slot.method == 'render_parent' and 'thread_root' or slot.key](original, current) end)
end

for key, slot in pairs(slots) do slot.key = key end

local function sync_all()
  for _, slot in pairs(slots) do sync(slot) end
  install_launch_provider()
end

function M.attach(next_ctx)
  if not next_ctx.enabled() then
    M.detach()
    return
  end
  ctx = next_ctx
  attached = true
  if not release_notification then
    release_notification = ctx.register_source({
      title = 'DAP',
      domain = DOMAIN,
      context = 'notification',
    })
  end
  sync_all()
end

function M.detach()
  attached = false
  repl_calls = setmetatable({}, { __mode = 'k' })
  clear_runtime_paths()
  restore_launch_provider()
  if release_notification then
    local release = release_notification
    release_notification = nil
    release()
  end
  for _, slot in pairs(slots) do
    if slot.generation ~= nil then common.unwrap(slot.records, slot.method) end
  end
end

local function seam_info(slot)
  local module = package.loaded[slot.module]
  local current = type(module) == 'table' and resolve_owner(slot, module) or nil
  if current == nil then return { active = false, reason = 'not_loaded' } end
  if current ~= slot.generation then return { active = false, reason = 'stale_generation' } end
  return {
    active = attached and common.active(slot.records, slot.method) or false,
    reason = common.reason(slot.records, slot.method),
  }
end

function M.info(current_ctx)
  local slot_info = {}
  local any_loaded, any_active, degraded = false, false, false
  for key, slot in pairs(slots) do
    local info = seam_info(slot)
    slot_info[key] = info
    any_loaded = any_loaded or info.reason ~= 'not_loaded'
    any_active = any_active or info.active
    degraded = degraded or info.reason == 'external_override'
      or info.reason == 'unsupported_api' or info.reason == 'stale_generation'
  end
  local reason = not attached and 'disabled'
    or not current_ctx.enabled() and 'disabled'
    or not any_loaded and 'not_loaded'
    or degraded and (any_active and 'partially_active' or 'external_override')
    or any_active and 'attached'
    or 'not_initialized'
  return {
    active = attached and current_ctx.enabled() and any_active or false,
    reason = reason,
    seam = 'vim.notify:title=DAP; dap.ui.pick_one(_sync); scoped REPL execution/new-buffer hooks and no-session reply; session/variable-action vim.fn.input; breakpoints.to_qf_list; health.check; synthetic thread root; dap.ui.widgets fixed messages; session exception diagnostics/spawn/connect; deprecated utils/vscode notify_once',
    domain = DOMAIN,
    notification = { active = release_notification ~= nil, title = 'DAP', context = 'notification' },
    slots = slot_info,
    existing_buffers = 'not_reattached; existing REPL prompt callbacks and rendered lines remain unchanged',
    uncovered = {
      'REPL dap> prompt, command tokens and DAP completion labels are behavior/data',
      'untitled vim.notify(_once) calls, eager user-command descriptions and launch.json prompts have no covered source-safe seam',
      'generic widget layer.render and progress.status mix plugin and debugger data and are not globally translated',
      'quickfix title DAP Breakpoints is an internal identity; protocol, logs, buffer names and diagnostics remain unchanged',
    },
  }
end

function M.signature()
  local values = {}
  for key, slot in pairs(slots) do
    local module = package.loaded[slot.module]
    local owner = type(module) == 'table' and resolve_owner(slot, module) or nil
    values[#values + 1] = key
    values[#values + 1] = tostring(owner)
    values[#values + 1] = type(owner) == 'table' and tostring(owner[slot.method]) or 'missing'
  end
  return table.concat(values, ':')
end

return M
