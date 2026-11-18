local common = require('nvim-zh.adapters.common')

local M = {
  name = 'nvim-dap',
  lazy_name = 'nvim-dap',
}

local DOMAIN = 'nvim-dap'
local COMMIT = 'cfa2d58f4537aca6ca83e2de1a0d9f1491121264'
local unpack = table.unpack or unpack
local attached = false
local ctx
local release_notification
local help_depth = 0
local stack_hint_depth = 0

local function enabled(slot, generation)
  return attached and ctx and ctx.enabled() and slot.generation == generation
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

local function with_help(fn, text, ...)
  if not is_help_command(text) then return fn(text, ...) end
  help_depth = help_depth + 1
  local results = common.pack(pcall(fn, text, ...))
  help_depth = help_depth - 1
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- new_buf() is private. These three public entry points are the fixed paths that
-- can create it. Scoped hooks cover both the public execute('.help') path and
-- the local callback used when a user types .help in a newly-created prompt.
local function with_repl_buffer_hooks(slot, generation, fn, ...)
  if not enabled(slot, generation) then return fn(...) end
  local original_keymap_set = vim.keymap.set
  local original_prompt_setcallback = vim.fn.prompt_setcallback
  local keymap_wrapper, prompt_wrapper

  if type(original_keymap_set) == 'function' then
    keymap_wrapper = function(mode, lhs, rhs, opts)
      if type(opts) ~= 'table' or type(opts.desc) ~= 'string' then
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
      if type(callback) ~= 'function' then return original_prompt_setcallback(buf, callback) end
      return original_prompt_setcallback(buf, function(text)
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
  local wrapper
  wrapper = function(prompt, ...)
    if not enabled(slot, generation) then return original_input(prompt, ...) end
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
    local function call(input, ...)
      if help_depth > 0 then
        input = translate('repl_help', input)
      elseif stack_hint_depth > 0 then
        input = translate('repl_hint', input)
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
    stack_hint_depth = stack_hint_depth + 1
    local results = common.pack(pcall(original, ...))
    stack_hint_depth = stack_hint_depth - 1
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
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

local function resolve_owner(slot, module)
  if slot.owner then return slot.owner(module) end
  return module
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
  help_depth, stack_hint_depth = 0, 0
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
    seam = 'vim.notify:title=DAP; dap.ui.pick_one(_sync); scoped REPL execution/new-buffer hooks; session/variable-action vim.fn.input; breakpoints.to_qf_list; health.check; synthetic thread root',
    domain = DOMAIN,
    supported_commit = COMMIT,
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
