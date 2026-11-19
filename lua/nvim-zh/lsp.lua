local M = {}
local engine = require('nvim-zh.engine')
local config = { messages = false, progress = false }
local states = {}
local unpack = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end

local function clangd(ctx)
  if type(ctx) ~= 'table' or type(ctx.client_id) ~= 'number' then return false end
  local ok, client = pcall(vim.lsp.get_client_by_id, ctx.client_id)
  return ok and type(client) == 'table' and client.name == 'clangd'
end

local function translate(context, text)
  if type(text) ~= 'string' or text == '' then return text end
  local ok, translated = pcall(engine.translate, {
    domain = 'clangd', context = context, msgid = text, formatted = true,
  })
  if ok and type(translated) == 'string' then return translated end
  return text
end

local function restore(method)
  local state = states[method]
  if not state then return end
  if vim.lsp.handlers[method] == state.wrapper then
    vim.lsp.handlers[method] = state.original
    states[method] = nil
  else
    state.active, state.reason = false, 'external_override'
  end
end

local function install(method, make_wrapper, enabled)
  local state = states[method]
  if not enabled then
    restore(method)
    return
  end
  if type(vim.lsp.handlers[method]) ~= 'function' then return end
  if state then
    state.active = vim.lsp.handlers[method] == state.wrapper
    state.reason = not state.active and 'external_override' or nil
    return
  end
  local original = vim.lsp.handlers[method]
  local wrapper = make_wrapper(original)
  states[method] = { original = original, wrapper = wrapper, active = true }
  vim.lsp.handlers[method] = wrapper
end

local function message_wrapper(original)
  return function(err, params, ctx, ...)
    if not config.messages or not clangd(ctx) or type(params) ~= 'table' then return original(err, params, ctx, ...) end
    local copy = {}
    for key, value in pairs(params) do copy[key] = value end
    copy.message = translate('show_message', params.message)
    return original(err, copy, ctx, ...)
  end
end

local function request_wrapper(original)
  return function(err, params, ctx, ...)
    if not config.messages or not clangd(ctx) or type(params) ~= 'table' then return original(err, params, ctx, ...) end
    local copy = {}
    for key, value in pairs(params) do copy[key] = value end
    copy.message = translate('request_message', params.message)
    local action_map = {}
    if type(params.actions) == 'table' then
      copy.actions = {}
      for index, action in ipairs(params.actions) do
        if type(action) == 'table' then
          local action_copy = {}
          for key, value in pairs(action) do action_copy[key] = value end
          action_copy.title = translate('action', action.title)
          copy.actions[index] = action_copy
          action_map[action_copy] = action
        else
          copy.actions[index] = action
        end
      end
    end
    local results = pack(original(err, copy, ctx, ...))
    if action_map[results[1]] then results[1] = action_map[results[1]] end
    return unpack(results, 1, results.n)
  end
end

local function progress_wrapper(original)
  return function(err, params, ctx, ...)
    if not config.progress or not clangd(ctx) or type(params) ~= 'table' or type(params.value) ~= 'table' then
      return original(err, params, ctx, ...)
    end
    local copy = {}
    for key, value in pairs(params) do copy[key] = value end
    copy.value = {}
    for key, value in pairs(params.value) do copy.value[key] = value end
    copy.value.title = translate('progress_title', params.value.title)
    copy.value.message = translate('progress_message', params.value.message)
    return original(err, copy, ctx, ...)
  end
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  install('window/showMessage', message_wrapper, config.messages)
  install('window/showMessageRequest', request_wrapper, config.messages)
  install('$/progress', progress_wrapper, config.progress)
end

function M.teardown()
  config = { messages = false, progress = false }
  restore('window/showMessage')
  restore('window/showMessageRequest')
  restore('$/progress')
end
function M.info()
  local result = { messages = config.messages, progress = config.progress, logMessage = 'source', domain = 'clangd' }
  for method, state in pairs(states) do result[method] = { active = state.active == true, reason = state.reason or (state.active and 'active') or 'external_override' } end
  return result
end
return M
