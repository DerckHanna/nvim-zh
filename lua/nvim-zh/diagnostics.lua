local M = {}
local engine = require('nvim-zh.engine')
local missing = require('nvim-zh.missing')
local config = { enabled = false }
local states = { virtual_text = {}, virtual_lines = {} }
local float_state = {}
local lists = {}
local unpack = table.unpack or unpack
local CONTEXTS = { 'redefinition', 'previous_definition', 'undeclared_identifier', 'unknown_type_name' }
local runtime = { observed = 0, translated = 0 }

local function is_clangd(diagnostic)
  local source = diagnostic.source
  -- clangd publishes its own findings as 'clangd', Clang diagnostics as
  -- 'clang', clang-tidy findings as 'clang-tidy', and configuration
  -- diagnostics as 'clangd-config'.
  if source == 'clangd' or source == 'clang' or source == 'clang-tidy'
    or source == 'clangd-config' then return true end
  if type(diagnostic.namespace) == 'number' then
    local ok, namespace = pcall(vim.diagnostic.get_namespace, diagnostic.namespace)
    return ok and type(namespace.name) == 'string' and namespace.name:match('^nvim%.lsp%.clangd%.%d') ~= nil
  end
  return false
end

local function lookup(context, text)
  local ok, result, status = pcall(engine.translate, {
    domain = 'clangd', context = context, msgid = text, formatted = true, observe = false,
  })
  if ok and status == 'translated' and type(result) == 'string' then return result, context end
end

local function translate_body(text, code, source)
  local result, context
  if type(code) == 'string' then
    result, context = lookup(code, text)
    if result then return result, context end
  end
  -- Configuration diagnostics arrive with substituted values, so only the
  -- fixed prefix can be matched; the clangd_config context holds those.
  if source == 'clangd-config' then
    result, context = lookup('clangd_config', text)
    if result then return result, context end
  end
  for _, legacy in ipairs(CONTEXTS) do
    result, context = lookup(legacy, text)
    if result then return result, context end
  end
  return lookup('diagnostic', text)
end

local function translate_sentence(text, code, source)
  local origin, inner = text:match('^(In [^:]+): (.+)$')
  local translated_origin = origin and lookup('diagnostic_origin', origin)
  if translated_origin then
    local translated, context = translate_sentence(inner:sub(1, 1):upper() .. inner:sub(2), code, source)
    return translated_origin .. '：' .. (translated or inner), context or 'diagnostic_origin'
  end
  local body, fixes = text:match('^(.*) %((fixe?s? available)%)$')
  body = body or text
  local result, context = translate_body(body, code, source)
  if result and fixes then
    result = result .. (lookup('diagnostic_suffix', ' (' .. fixes .. ')') or (' (' .. fixes .. ')'))
  elseif fixes then
    return translate_body(text, code, source)
  end
  return result, context
end

local function translate_diagnostic(diagnostic, text, code)
  if type(text) ~= 'string' or text == '' or type(diagnostic) ~= 'table' or not is_clangd(diagnostic) then return text end
  runtime.observed = runtime.observed + 1
  local result, context
  local source = diagnostic.source
  local first, notes = text:match('^(.-)(\n\n.*)$')
  if first and notes:match('^\n\n[^\n]*:%d+:%d+[%s:]+') then
    result, context = translate_sentence(first, code, source)
    notes = notes:gsub('(\n\n[^\n]-:%d+:%d+[%s:]+)([a-z ]+): ([^\n]+)', function(location, level, note)
      local translated = translate_sentence(note:sub(1, 1):upper() .. note:sub(2), code, source)
      return location .. (lookup('diagnostic_level', level) or level) .. ': ' .. (translated or note)
    end)
    result = (result or first) .. notes
    if result == text then result = nil end
  else
    result, context = translate_sentence(text, code, source)
  end
  if result then runtime.translated = runtime.translated + 1 end
  missing.observe({ domain = 'clangd', context = context or '', msgid = text, dynamic = true, translated = result ~= nil })
  return result or text
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
      text = translate_diagnostic(diagnostic, text, diagnostic.code)
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

local function float_suffix(suffix)
  return function(diagnostic, ...)
    local text, hl
    if type(suffix) == 'function' then
      text, hl = suffix(diagnostic, ...)
    elseif type(suffix) == 'table' then
      text, hl = suffix[1], suffix[2]
    elseif type(suffix) == 'string' then
      text = suffix
    else
      text = diagnostic.code and (' [%s]'):format(diagnostic.code) or ''
    end
    if config.enabled and config.float and is_clangd(diagnostic) then
      -- Neovim calls suffix on a deep copy produced by opts.format, then renders its related locations.
      local related = vim.tbl_get(diagnostic, 'user_data', 'lsp', 'relatedInformation')
      if type(related) == 'table' then
        for _, item in ipairs(related) do
          if type(item) == 'table' then item.message = translate_diagnostic(diagnostic, item.message) end
        end
      end
    end
    return text, hl
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
    if user_format == nil and type(global_float) == 'function' then return original(opts, ...) end
    if user_format == nil and type(global_float) == 'table' then user_format = global_float.format end
    if user_format ~= nil and type(user_format) ~= 'function' then return original(opts, ...) end
    copy.format = make_formatter(user_format, 'float')
    if vim.fn.has('nvim-0.12') == 1 then
      local suffix = copy.suffix
      if suffix == nil and type(global_float) == 'table' then suffix = global_float.suffix end
      if (suffix ~= nil or type(global_float) ~= 'function')
        and (not suffix or type(suffix) == 'function' or type(suffix) == 'string' or type(suffix) == 'table') then
        copy.suffix = float_suffix(suffix)
      end
    end
    if old_signature then
      args[1] = copy
      if args.n == 0 then args.n = 1 end
      return original(opts, unpack(args, 1, args.n))
    end
    return original(copy, ...)
  end
  float_state.original, float_state.wrapper = original, wrapper
  float_state.active, float_state.reason = true, nil
  vim.diagnostic.open_float = wrapper
end

local function setup_lists()
  for _, name in ipairs({ 'setqflist', 'setloclist' }) do
    local state = lists[name]
    if config.enabled and config.lists and vim.fn.has('nvim-0.12') == 1 then
      if not state and type(vim.diagnostic[name]) == 'function' then
        local original = vim.diagnostic[name]
        local wrapper = function(opts, ...)
          if not config.enabled or not config.lists or (opts ~= nil and type(opts) ~= 'table') then
            return original(opts, ...)
          end
          local copy = vim.tbl_extend('force', {}, opts or {})
          if copy.format ~= nil and type(copy.format) ~= 'function' then return original(opts, ...) end
          copy.format = make_formatter(copy.format, 'lists')
          return original(copy, ...)
        end
        lists[name] = { original = original, wrapper = wrapper }
        vim.diagnostic[name] = wrapper
      end
    elseif state and vim.diagnostic[name] == state.wrapper then
      vim.diagnostic[name] = state.original
      lists[name] = nil
    end
  end
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  setup_display('virtual_text', states.virtual_text)
  setup_display('virtual_lines', states.virtual_lines)
  setup_float()
  setup_lists()
end

function M.teardown()
  config = { enabled = false }
  restore_display('virtual_text', states.virtual_text)
  restore_display('virtual_lines', states.virtual_lines)
  restore_float()
  setup_lists()
end

function M.info()
  local result = {
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
  for _, name in ipairs({ 'setqflist', 'setloclist' }) do
    local enabled = config.enabled and config.lists == true
    local active = enabled and lists[name] ~= nil and vim.diagnostic[name] == lists[name].wrapper
    result[name] = { enabled = enabled, active = active, reason = active and 'active'
      or not enabled and 'disabled' or lists[name] and 'external_override' or 'unsupported_api' }
  end
  return result
end

return M
