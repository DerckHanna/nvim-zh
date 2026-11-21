local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'mini'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
  statusline_generation = nil,
  statusline_records = {},
  surround_generation = nil,
  surround_records = {},
  ai_generation = nil,
  ai_records = {},
}

local SURROUND_METHODS = {
  'add',
  'delete',
  'replace',
  'find',
  'highlight',
  'update_n_lines',
}

local AI_METHODS = {
  'find_textobject',
  'select_textobject',
  'move_cursor',
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

local function statusline_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and state.statusline_generation ~= nil and rawequal(state.statusline_generation, generation)
    and rawequal(package.loaded['mini.statusline'], generation)
    and common.active(state.statusline_records, 'section_mode')
    and verify('statusline') ~= nil
end

local function prompts_enabled(generation, module_name)
  return state.enabled and state.ctx and state.ctx.enabled()
    and generation ~= nil and rawequal(package.loaded[module_name], generation)
    and verify('prompts_and_feedback') ~= nil
end

local function with_scoped_feedback(fn, ...)
  local prev_echo = vim.api.nvim_echo
  local prev_strcharpart = vim.fn.strcharpart
  local prev_input = vim.fn.input

  local strcharpart_proxy = function(str, start, len, ...)
    if type(str) == 'string' and start == 0 and not str:match('^%(mini%.') then
      str = translate('echo', str)
    end
    return prev_strcharpart(str, start, len, ...)
  end

  local echo_proxy = function(chunks, history, opts)
    if type(chunks) == 'table' then
      local copy_chunks = {}
      for i, chunk in ipairs(chunks) do
        if type(chunk) == 'table' and type(chunk[1]) == 'string' and not chunk[1]:match('^%(mini%.') then
          local c = common.copy(chunk)
          c[1] = translate('echo', c[1])
          copy_chunks[i] = c
        else
          copy_chunks[i] = chunk
        end
      end
      chunks = copy_chunks
    end
    return prev_echo(chunks, history, opts)
  end

  local input_proxy = function(first, ...)
    if type(first) == 'table' and type(first.prompt) == 'string' then
      local copy = common.copy(first)
      copy.prompt = translate('prompt', copy.prompt)
      first = copy
    elseif type(first) == 'string' then
      first = translate('prompt', first)
    end
    return prev_input(first, ...)
  end

  vim.fn.strcharpart = strcharpart_proxy
  vim.api.nvim_echo = echo_proxy
  vim.fn.input = input_proxy

  local results = common.pack(pcall(fn, ...))

  if vim.fn.strcharpart == strcharpart_proxy then vim.fn.strcharpart = prev_strcharpart end
  if vim.api.nvim_echo == echo_proxy then vim.api.nvim_echo = prev_echo end
  if vim.fn.input == input_proxy then vim.fn.input = prev_input end

  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local function sync_statusline()
  local current = package.loaded['mini.statusline']
  if current ~= state.statusline_generation then
    if state.statusline_generation ~= nil then
      common.unwrap(state.statusline_records, 'section_mode')
    end
    state.statusline_records = {}
    state.statusline_generation = current
  end
  if type(current) ~= 'table' or type(current.section_mode) ~= 'function' then return end
  common.wrap(state.statusline_records, 'section_mode', function()
    return current.section_mode
  end, function(value)
    current.section_mode = value
  end, function(original)
    return function(args, ...)
      local mode, hl = original(args, ...)
      if statusline_enabled(current) and type(mode) == 'string' and #mode > 3 then
        mode = translate('mode', mode)
      end
      return mode, hl
    end
  end)
end

local function sync_surround()
  local current = package.loaded['mini.surround']
  if current ~= state.surround_generation then
    if state.surround_generation ~= nil then
      common.unwrap(state.surround_records, 'user_input')
      for _, method in ipairs(SURROUND_METHODS) do
        common.unwrap(state.surround_records, method)
      end
    end
    state.surround_records = {}
    state.surround_generation = current
  end
  if type(current) ~= 'table' then return end
  if type(current.user_input) == 'function' then
    common.wrap(state.surround_records, 'user_input', function()
      return current.user_input
    end, function(value)
      current.user_input = value
    end, function(original)
      return function(prompt, text, ...)
        if prompts_enabled(current, 'mini.surround')
            and common.active(state.surround_records, 'user_input') and type(prompt) == 'string' then
          prompt = translate('prompt', prompt)
        end
        return original(prompt, text, ...)
      end
    end)
  end
  for _, method in ipairs(SURROUND_METHODS) do
    if type(current[method]) == 'function' then
      common.wrap(state.surround_records, method, function()
        return current[method]
      end, function(value)
        current[method] = value
      end, function(original)
        return function(...)
          if not prompts_enabled(current, 'mini.surround')
              or not common.active(state.surround_records, method) then
            return original(...)
          end
          return with_scoped_feedback(original, ...)
        end
      end)
    end
  end
end

local function sync_ai()
  local current = package.loaded['mini.ai']
  if current ~= state.ai_generation then
    if state.ai_generation ~= nil then
      for _, method in ipairs(AI_METHODS) do
        common.unwrap(state.ai_records, method)
      end
    end
    state.ai_records = {}
    state.ai_generation = current
  end
  if type(current) ~= 'table' then return end
  for _, method in ipairs(AI_METHODS) do
    if type(current[method]) == 'function' then
      common.wrap(state.ai_records, method, function()
        return current[method]
      end, function(value)
        current[method] = value
      end, function(original)
        return function(...)
          if not prompts_enabled(current, 'mini.ai')
              or not common.active(state.ai_records, method) then
            return original(...)
          end
          return with_scoped_feedback(original, ...)
        end
      end)
    end
  end
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = true
  sync_statusline()
  sync_surround()
  sync_ai()
end

function M.detach()
  state.enabled = false
  common.unwrap(state.statusline_records, 'section_mode')
  state.statusline_records = {}
  state.statusline_generation = nil
  common.unwrap(state.surround_records, 'user_input')
  for _, method in ipairs(SURROUND_METHODS) do
    common.unwrap(state.surround_records, method)
  end
  state.surround_records = {}
  state.surround_generation = nil
  for _, method in ipairs(AI_METHODS) do
    common.unwrap(state.ai_records, method)
  end
  state.ai_records = {}
  state.ai_generation = nil
end

function M.signature()
  local sl = package.loaded['mini.statusline']
  local sr = package.loaded['mini.surround']
  local ai = package.loaded['mini.ai']
  return table.concat({
    tostring(sl),
    type(sl) == 'table' and tostring(sl.section_mode) or '',
    tostring(sr),
    type(sr) == 'table' and tostring(sr.user_input) or '',
    tostring(ai),
    type(ai) == 'table' and tostring(ai.find_textobject) or '',
  }, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local sl_verified, sl_why = verify('statusline')
  local pf_verified, pf_why = verify('prompts_and_feedback')

  local sl_active = enabled and sl_verified ~= nil and common.active(state.statusline_records, 'section_mode')
  local pf_active = enabled and pf_verified ~= nil and (
    common.active(state.surround_records, 'user_input')
    or common.active(state.ai_records, 'find_textobject')
  )

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(state.statusline_records, 'section_mode') == 'external_override'
      or common.reason(state.surround_records, 'user_input') == 'external_override' then
    reason = 'external_override'
  elseif sl_active or pf_active then
    reason = nil
  elseif package.loaded['mini.statusline'] == nil and package.loaded['mini.surround'] == nil
      and package.loaded['mini.ai'] == nil then
    reason = 'not_loaded'
  else
    reason = sl_why or pf_why or common.reason(state.statusline_records, 'section_mode')
  end

  return {
    active = sl_active or pf_active,
    reason = reason,
    seam = 'MiniStatusline.section_mode; MiniSurround.user_input; MiniSurround.{add,delete,replace,find,highlight,update_n_lines}; MiniAi.{find_textobject,select_textobject,move_cursor}',
    domain = DOMAIN,
    statusline = {
      active = sl_active,
      reason = sl_verified and common.reason(state.statusline_records, 'section_mode') or sl_why,
    },
    prompts_and_feedback = {
      active = pf_active,
      reason = pf_verified and common.reason(state.surround_records, 'user_input') or pf_why,
    },
  }
end

return M
