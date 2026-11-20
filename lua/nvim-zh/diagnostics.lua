local M = {}
local engine = require('nvim-zh.engine')
local missing = require('nvim-zh.missing')
local packs = require('nvim-zh.packs')
local config = { enabled = false }
local states = { virtual_text = {}, virtual_lines = {} }
local float_state = {}
local lists = {}
local unpack = table.unpack or unpack
local CONTEXTS = { 'redefinition', 'previous_definition', 'undeclared_identifier', 'unknown_type_name' }
local runtime = { observed = 0, translated = 0 }
local raw_codes = {
  pp_hash_error = true, pp_hash_warning = true, pragma_message = true, warn_pragma_message = true,
  apinotes_message = true, note_apinotes_message = true, warn_apinotes_message = true,
  diagnose_if_succeeded = true, warn_diagnose_if_succeeded = true, inline_ms_asm_parsing = true,
  ['-Wuser-defined-warnings'] = true, ['-Wapinotes'] = true, ['-W#warnings'] = true,
  ['-W#pragma-messages'] = true, ['-Winline-asm'] = true, ['-Wsource-mgr'] = true,
}

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

local function lookup(context, text, args)
  local ok, result, status, id = pcall(engine.translate, {
    domain = 'clangd', context = context, msgid = text, args = args, formatted = true,
    observe = false, report_ambiguity = true,
  })
  if ok and status == 'translated' and type(result) == 'string' then return result, context, id, status end
  if ok and status == 'ambiguous' then return nil, context, nil, status end
end

local function translate_body(text, code, source, note)
  local contexts = {}
  if note then contexts[#contexts + 1] = 'related_diagnostic' end
  if type(code) == 'string' then
    contexts[#contexts + 1] = code
  end
  -- Configuration diagnostics arrive with substituted values, so only the
  -- fixed prefix can be matched; the clangd_config context holds those.
  if source == 'clangd-config' then
    contexts[#contexts + 1] = 'clangd_config'
  end
  vim.list_extend(contexts, CONTEXTS)
  contexts[#contexts + 1] = 'diagnostic'
  for _, context in ipairs(contexts) do
    local result, _, id, status = lookup(context, text)
    if status then return result, context, id, status end
  end
end

local function translate_sentence(text, code, source, note)
  if raw_codes[code] then return nil, nil, nil, 'project_text' end
  local origin, inner = text:match('^(In [^:]+): (.+)$')
  local translated_origin, _, origin_id, origin_status
  if origin then translated_origin, _, origin_id, origin_status = lookup('diagnostic_origin', origin) end
  if origin_status == 'ambiguous' then return nil, 'diagnostic_origin', nil, origin_status end
  if translated_origin then
    local translated, context, id, status, nested_id =
      translate_sentence(inner:sub(1, 1):upper() .. inner:sub(2), code, source, note)
    if status == 'ambiguous' then return nil, context, nil, status end
    return translated_origin .. '：' .. (translated or inner), context or 'diagnostic_origin',
      id or origin_id, status or 'partial_translation', nested_id
  end
  if note then
    local conjunction, expression, diagnostic = text:match("^([A-Za-z]+) '([^']+)' would be invalid: (.+)$")
    conjunction = conjunction and conjunction:lower()
    if conjunction == 'because' or conjunction == 'and' then
      local nested, context, nested_id, status = lookup('substitution_diagnostic', diagnostic)
      if status == 'ambiguous' then return nil, context, nil, status end
      if nested then
        local key = conjunction:sub(1, 1):upper() .. conjunction:sub(2) .. " '%1' would be invalid: %2"
        local result, scope, id, reason = lookup('related_diagnostic', key, { ['1'] = expression, ['2'] = nested })
        if reason then return result, scope, id, reason, nested_id end
      end
    end
  end
  local body, fixes = text:match('^(.*) %((fixe?s? available)%)$')
  body = body or text
  local result, context, id, status = translate_body(body, code, source, note)
  if status == 'ambiguous' then return nil, context, nil, status end
  if result and fixes then
    local suffix = lookup('diagnostic_suffix', ' (' .. fixes .. ')')
    result = result .. (suffix or (' (' .. fixes .. ')'))
    if not suffix then status = 'partial_translation' end
  elseif fixes then
    return translate_body(text, code, source, note)
  end
  return result, context, id, status
end

-- Used by the source inventory to exercise the same message matcher.
M.match_message = translate_sentence

function M.match_forwarded(text, code, note)
  local body, fixes = text:match('^(.*) %((fixe?s? available)%)$')
  body = body or text
  local cli_body = body:sub(1, 1):lower() .. body:sub(2)
  local match = require('nvim-zh.compiler').match_message
  local level = note and 'note' or nil
  local translated, reason, context, id = match('clang-tidy', cli_body, code, level)
  if reason == 'missing_translation' and cli_body ~= body then
    translated, reason, context, id = match('clang-tidy', body, code, level)
  end
  if reason ~= 'translated' then return text, reason end
  local suffix = fixes and (lookup('diagnostic_suffix', ' (' .. fixes .. ')') or (' (' .. fixes .. ')')) or ''
  return translated .. suffix, reason, context, id
end

local function translate_diagnostic(diagnostic, text, code, note)
  if type(text) ~= 'string' or text == '' or type(diagnostic) ~= 'table' or not is_clangd(diagnostic) then return text end
  if raw_codes[code] then
    runtime.observed = runtime.observed + 1
    return text
  end
  local ns = diagnostic.namespace and vim.diagnostic.get_namespace(diagnostic.namespace)
  local id, remainder
  if ns then id, remainder = ns.name:match('^nvim%.lsp%.clangd%.(%d+)(.*)$') end
  local client = id and vim.lsp.get_client_by_id(tonumber(id))
  local method = remainder and remainder ~= '' and 'textDocument/diagnostic' or 'textDocument/publishDiagnostics'
  if not packs.tool_allows('clangd', client, method) then return text end
  runtime.observed = runtime.observed + 1
  local result, context
  local source = diagnostic.source
  if source == 'clang-tidy' and client and packs.tool_reason('clangd', client, method) == 'verified' then
    if packs.tool_reason('clang-tidy', client, 'forwarded_diagnostics') ~= 'verified' then return text end
    local translated, reason = M.match_forwarded(text, code, note)
    if reason == 'translated' then runtime.translated = runtime.translated + 1 end
    return translated
  end
  local first, notes = text:match('^(.-)(\n\n.*)$')
  if first and notes:match('^\n\n[^\n]*:%d+:%d+[%s:]+') then
    result, context = translate_sentence(first, code, source)
    notes = notes:gsub('(\n\n[^\n]-:%d+:%d+[%s:]+)([a-z ]+): ([^\n]+)', function(location, level, note)
      local translated = translate_sentence(note:sub(1, 1):upper() .. note:sub(2), code, source, true)
      return location .. (lookup('diagnostic_level', level) or level) .. ': ' .. (translated or note)
    end)
    result = (result or first) .. notes
    if result == text then result = nil end
  else
    result, context = translate_sentence(text, code, source, note)
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
          if type(item) == 'table' then
            item.message = translate_diagnostic(diagnostic, item.message, diagnostic.code, true)
          end
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
