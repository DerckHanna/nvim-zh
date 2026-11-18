local M = {}
local engine = require('nvim-zh.engine')
local missing = require('nvim-zh.missing')
local config = { enabled = false, virtual_text = true, virtual_lines = true, float = true }
local states = { virtual_text = {}, virtual_lines = {} }
local float_state = {}
local unpack = table.unpack or unpack
local CONTEXTS = { 'redefinition', 'previous_definition', 'undeclared_identifier', 'unknown_type_name' }
local runtime = { observed = 0, translated = 0 }

local function translate_diagnostic(diagnostic, text)
  if type(text) ~= 'string' or type(diagnostic) ~= 'table' then return text end
  if diagnostic.source ~= 'clangd' and diagnostic.source ~= 'clang' then return text end
  runtime.observed = runtime.observed + 1
  for _, context in ipairs(CONTEXTS) do
    local ok, translated, status = pcall(engine.translate, {
      domain = 'clangd', context = context, msgid = text, formatted = true, observe = false,
    })
    if ok and status == 'translated' and type(translated) == 'string' then
      runtime.translated = runtime.translated + 1
      missing.observe({
        domain = 'clangd', context = context, msgid = text, dynamic = true, translated = true,
      })
      return translated
    end
  end
  -- Context probes are implementation details, not independent observations.
  missing.observe({ domain = 'clangd', context = '', msgid = text, dynamic = true, translated = false })
  return text
end

local function make_formatter(user_format, display)
  return function(diagnostic)
    local text
    if user_format then
      text = user_format(diagnostic)
    else
      text = diagnostic.message
    end
    -- A user formatter may return nil to suppress a diagnostic. Retained
    -- callbacks must also become inert when their module or display is disabled.
    if config.enabled and config[display] then
      text = translate_diagnostic(diagnostic, text)
    end
    -- Preserve Neovim's default virtual_lines rendering when no user formatter
    -- was supplied (0.11.5 and the pinned 0.12.6 use the same code prefix).
    -- https://github.com/neovim/neovim/blob/v0.11.5/runtime/lua/vim/diagnostic.lua
    if not user_format and display == 'virtual_lines' and diagnostic.code then
      return ('%s: %s'):format(diagnostic.code, text)
    end
    return text
  end
end

local function restore_display(name, state)
  if not state.formatter then return end
  local current = vim.diagnostic.config()[name]
  if type(current) == 'table' and current.format == state.formatter then
    -- Own only the formatter, not unrelated options changed since setup.
    local options = vim.deepcopy(current)
    options.format = state.original_format
    if state.original_bare and next(options) == nil then options = true end
    vim.diagnostic.config({ [name] = options })
    state.formatter, state.original_format, state.original_bare, state.user_format = nil, nil, nil, nil
    state.active, state.reason = false, 'disabled'
  else
    state.active, state.reason = false, 'external_override'
  end
end

local function setup_display(name, state)
  if not config.enabled or not config[name] then
    restore_display(name, state)
    if not state.formatter then state.active, state.reason = false, 'disabled' end
    return
  end
  local current = vim.diagnostic.config()[name]
  if state.formatter then
    if type(current) == 'table' and current.format == state.formatter then
      state.active, state.reason = true, nil
    else
      state.active, state.reason = false, 'external_override'
    end
    return
  end
  -- Never enable a display the user disabled. A table/true is an existing display seam.
  if current ~= true and type(current) ~= 'table' then
    state.active, state.reason = false, 'display_disabled'
    return
  end
  local user_format = type(current) == 'table' and current.format or nil
  if user_format ~= nil and type(user_format) ~= 'function' then
    state.active, state.reason = false, 'unsupported_formatter'
    return
  end
  local options = type(current) == 'table' and vim.deepcopy(current) or {}
  local formatter = make_formatter(user_format, name)
  options.format = formatter
  state.original_format, state.original_bare = user_format, current == true
  state.user_format, state.formatter = user_format, formatter
  vim.diagnostic.config({ [name] = options })
  state.active, state.reason = true, nil
end

local function restore_float()
  if not float_state.wrapper then return end
  if vim.diagnostic.open_float == float_state.wrapper then
    vim.diagnostic.open_float = float_state.original
    float_state.wrapper, float_state.original = nil, nil
    float_state.active, float_state.reason = false, 'disabled'
  else
    float_state.active, float_state.reason = false, 'external_override'
  end
end

local function setup_float()
  if not config.enabled or not config.float then
    restore_float()
    if not float_state.wrapper then float_state.active, float_state.reason = false, 'disabled' end
    return
  end
  if type(vim.diagnostic.open_float) ~= 'function' then
    float_state.active, float_state.reason = false, 'unsupported_api'
    return
  end
  if float_state.wrapper then
    if vim.diagnostic.open_float == float_state.wrapper then
      float_state.active, float_state.reason = true, nil
    else
      float_state.active, float_state.reason = false, 'external_override'
    end
    return
  end
  local original = vim.diagnostic.open_float
  local wrapper = function(opts, ...)
    if not config.enabled or not config.float then return original(opts, ...) end
    local args = { n = select('#', ...), ... }
    local current, old_signature = opts, false
    if type(opts) ~= 'table' then current, old_signature = args[1], true end
    if current ~= nil and type(current) ~= 'table' then return original(opts, ...) end
    local copy = {}
    for key, value in pairs(current or {}) do copy[key] = value end
    local global_float = vim.diagnostic.config().float
    local user_format = copy.format
    if user_format == nil and type(global_float) == 'table' then user_format = global_float.format end
    if user_format ~= nil and type(user_format) ~= 'function' then return original(opts, ...) end
    copy.format = make_formatter(user_format, 'float')
    if old_signature then
      args[1] = copy
      if args.n == 0 then args.n = 1 end
      return original(opts, unpack(args, 1, args.n))
    end
    return original(copy)
  end
  float_state.original, float_state.wrapper = original, wrapper
  float_state.active, float_state.reason = true, nil
  vim.diagnostic.open_float = wrapper
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  setup_display('virtual_text', states.virtual_text)
  setup_display('virtual_lines', states.virtual_lines)
  setup_float()
end

function M.teardown()
  config = { enabled = false, virtual_text = false, virtual_lines = false, float = false }
  restore_display('virtual_text', states.virtual_text)
  restore_display('virtual_lines', states.virtual_lines)
  restore_float()
end

function M.info()
  return {
    enabled = config.enabled,
    virtual_text = {
      enabled = config.enabled and config.virtual_text == true,
      active = states.virtual_text.active == true, reason = states.virtual_text.reason or 'not_initialized',
    },
    virtual_lines = {
      enabled = config.enabled and config.virtual_lines == true,
      active = states.virtual_lines.active == true, reason = states.virtual_lines.reason or 'not_initialized',
    },
    float = {
      enabled = config.enabled and config.float == true,
      active = float_state.active == true, reason = float_state.reason or 'not_initialized',
    },
    domain = 'clangd',
    runtime_observed = runtime.observed, runtime_translated = runtime.translated,
  }
end

return M
