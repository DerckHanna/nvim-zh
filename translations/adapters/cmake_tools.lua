local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'cmake-tools'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
  release_source = nil,
  source_error = nil,
  cmake_generation = nil,
  cmake_records = {},
  log_generation = nil,
  log_records = {},
  notify_generation = nil,
  notify_records = {},
  window_generation = nil,
  window_records = {},
  quickstart_generation = nil,
  quickstart_records = {},
}

local PROMPT_METHODS = {
  'quick_build',
  'quick_run',
  'select_build_type',
  'select_kit',
  'select_configure_preset',
  'select_test_preset',
  'select_build_preset',
  'select_build_target',
  'select_launch_target',
  'get_cmake_launch_targets',
  'settings',
  'target_settings',
  'run_test',
  'run_current_file',
  'build_current_file',
  'select_cwd',
  'select_build_dir',
  'quick_debug',
  'debug_current_file',
  'inspect_launch_target',
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

local function prompts_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and generation ~= nil and verify('prompts') ~= nil
end

local function notify_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and generation ~= nil and verify('notifications') ~= nil
end

local function with_scoped_prompts(fn, ...)
  local prev_select = vim.ui.select
  local prev_input = vim.ui.input

  local select_proxy, input_proxy

  local function wrap_callback(cb)
    if type(cb) ~= 'function' then return cb end
    return function(...)
      return with_scoped_prompts(cb, ...)
    end
  end

  select_proxy = function(items, opts, on_choice)
    if type(opts) == 'table' and type(opts.prompt) == 'string' and opts.prompt ~= '' then
      local copy = common.copy(opts)
      copy.prompt = translate('prompt', opts.prompt)
      opts = copy
    end
    return prev_select(items, opts, wrap_callback(on_choice))
  end

  input_proxy = function(opts, on_confirm)
    if type(opts) == 'table' and type(opts.prompt) == 'string' and opts.prompt ~= '' then
      local copy = common.copy(opts)
      copy.prompt = translate('prompt', opts.prompt)
      opts = copy
    end
    return prev_input(opts, wrap_callback(on_confirm))
  end

  vim.ui.select = select_proxy
  vim.ui.input = input_proxy
  local results = common.pack(pcall(fn, ...))
  if vim.ui.select == select_proxy then vim.ui.select = prev_select end
  if vim.ui.input == input_proxy then vim.ui.input = prev_input end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local function sync_cmake()
  local current = package.loaded['cmake-tools']
  if current ~= state.cmake_generation then
    if state.cmake_generation ~= nil then
      for _, method in ipairs(PROMPT_METHODS) do
        common.unwrap(state.cmake_records, method)
      end
    end
    state.cmake_records = {}
    state.cmake_generation = current
  end
  if type(current) ~= 'table' then return end
  for _, method in ipairs(PROMPT_METHODS) do
    if type(current[method]) == 'function' then
      common.wrap(state.cmake_records, method, function()
        return current[method]
      end, function(value)
        current[method] = value
      end, function(original)
        return function(...)
          if not prompts_enabled(current) or not rawequal(package.loaded['cmake-tools'], current)
              or not common.active(state.cmake_records, method) then
            return original(...)
          end
          return with_scoped_prompts(original, ...)
        end
      end)
    end
  end
end

local function sync_window()
  local current = package.loaded['cmake-tools.window']
  if current ~= state.window_generation then
    if state.window_generation ~= nil then
      common.unwrap(state.window_records, 'open')
    end
    state.window_records = {}
    state.window_generation = current
  end
  if type(current) ~= 'table' or type(current.open) ~= 'function' then return end
  common.wrap(state.window_records, 'open', function()
    return current.open
  end, function(value)
    current.open = value
  end, function(original)
    return function(...)
      if not prompts_enabled(current) or not rawequal(package.loaded['cmake-tools.window'], current)
          or not common.active(state.window_records, 'open') then
        return original(...)
      end
      local prev_title = current.title
      if type(prev_title) == 'string' and prev_title ~= '' then
        current.title = translate('prompt', prev_title)
      end
      local results = common.pack(pcall(original, ...))
      current.title = prev_title
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end
  end)
end

local function sync_quickstart()
  local current = package.loaded['cmake-tools.quickstart']
  if current ~= state.quickstart_generation then
    if state.quickstart_generation ~= nil then
      common.unwrap(state.quickstart_records, 'quick_start')
    end
    state.quickstart_records = {}
    state.quickstart_generation = current
  end
  if type(current) ~= 'table' or type(current.quick_start) ~= 'function' then return end
  common.wrap(state.quickstart_records, 'quick_start', function()
    return current.quick_start
  end, function(value)
    current.quick_start = value
  end, function(original)
    return function(...)
      if not prompts_enabled(current) or not rawequal(package.loaded['cmake-tools.quickstart'], current)
          or not common.active(state.quickstart_records, 'quick_start') then
        return original(...)
      end
      return with_scoped_prompts(original, ...)
    end
  end)
end

local function sync_log()
  local current = package.loaded['cmake-tools.log']
  if current ~= state.log_generation then
    if state.log_generation ~= nil then
      common.unwrap(state.log_records, 'notify')
    end
    state.log_records = {}
    state.log_generation = current
  end
  if type(current) ~= 'table' or type(current.notify) ~= 'function' then return end
  common.wrap(state.log_records, 'notify', function()
    return current.notify
  end, function(value)
    current.notify = value
  end, function(original)
    return function(msg, log_level, ...)
      if notify_enabled(current) and rawequal(package.loaded['cmake-tools.log'], current)
          and common.active(state.log_records, 'notify') and type(msg) == 'string' then
        msg = translate('notification', msg)
      end
      return original(msg, log_level, ...)
    end
  end)
end

local function sync_notification()
  local current = package.loaded['cmake-tools.notification']
  if current ~= state.notify_generation then
    if state.notify_generation ~= nil then
      common.unwrap(state.notify_records, 'notify')
    end
    state.notify_records = {}
    state.notify_generation = current
  end
  if type(current) ~= 'table' or type(current.notify) ~= 'function' then return end
  common.wrap(state.notify_records, 'notify', function()
    return current.notify
  end, function(value)
    current.notify = value
  end, function(original)
    return function(self, msg, level, opts, ...)
      if notify_enabled(current) and rawequal(package.loaded['cmake-tools.notification'], current)
          and common.active(state.notify_records, 'notify') and type(msg) == 'string' then
        msg = translate('notification', msg)
      end
      return original(self, msg, level, opts, ...)
    end
  end)
end

local function ensure_source(ctx)
  if state.release_source or type(ctx.register_source) ~= 'function' then return end
  local ok, release = pcall(ctx.register_source, {
    title = 'CMakeTools',
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
  sync_cmake()
  sync_window()
  sync_quickstart()
  sync_log()
  sync_notification()
end

function M.detach()
  state.enabled = false
  release_source()
  for _, method in ipairs(PROMPT_METHODS) do
    common.unwrap(state.cmake_records, method)
  end
  state.cmake_records = {}
  state.cmake_generation = nil
  common.unwrap(state.window_records, 'open')
  state.window_records = {}
  state.window_generation = nil
  common.unwrap(state.quickstart_records, 'quick_start')
  state.quickstart_records = {}
  state.quickstart_generation = nil
  common.unwrap(state.log_records, 'notify')
  state.log_records = {}
  state.log_generation = nil
  common.unwrap(state.notify_records, 'notify')
  state.notify_records = {}
  state.notify_generation = nil
end

function M.signature()
  local cmake = package.loaded['cmake-tools']
  local log = package.loaded['cmake-tools.log']
  local ntfy = package.loaded['cmake-tools.notification']
  local win = package.loaded['cmake-tools.window']
  local qs = package.loaded['cmake-tools.quickstart']
  return table.concat({
    tostring(cmake),
    type(cmake) == 'table' and tostring(cmake.select_build_type) or '',
    tostring(log),
    type(log) == 'table' and tostring(log.notify) or '',
    tostring(ntfy),
    type(ntfy) == 'table' and tostring(ntfy.notify) or '',
    tostring(win),
    type(win) == 'table' and tostring(win.open) or '',
    tostring(qs),
    type(qs) == 'table' and tostring(qs.quick_start) or '',
  }, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local prompts_verified, prompts_why = verify('prompts')
  local notify_verified, notify_why = verify('notifications')

  local prompts_active = enabled and prompts_verified ~= nil and (
    common.active(state.cmake_records, 'select_build_type')
    or common.active(state.window_records, 'open')
    or common.active(state.quickstart_records, 'quick_start')
  )
  local notify_active = enabled and notify_verified ~= nil and (
    common.active(state.log_records, 'notify')
    or common.active(state.notify_records, 'notify')
  )

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(state.cmake_records, 'select_build_type') == 'external_override'
      or common.reason(state.log_records, 'notify') == 'external_override' then
    reason = 'external_override'
  elseif prompts_active or notify_active then
    reason = nil
  elseif package.loaded['cmake-tools'] == nil and package.loaded['cmake-tools.log'] == nil then
    reason = 'not_loaded'
  else
    reason = prompts_why or notify_why or common.reason(state.cmake_records, 'select_build_type')
  end

  return {
    active = prompts_active or notify_active,
    reason = reason,
    seam = 'vim.notify:title=CMakeTools; cmake-tools.log.notify; cmake-tools.notification.notify; cmake-tools interactive select/input prompt projection; cmake-tools.window.open title projection',
    domain = DOMAIN,
    prompts = {
      active = prompts_active,
      reason = prompts_verified and common.reason(state.cmake_records, 'select_build_type') or prompts_why,
    },
    notifications = {
      active = notify_active,
      reason = notify_verified and common.reason(state.log_records, 'notify') or notify_why,
      error = state.source_error,
    },
  }
end

return M
