local M = {}
local engine = require('nvim-zh.engine')
local config = {}
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
  if state.target[method] == state.wrapper then
    state.target[method] = state.original
    states[method] = nil
  else
    state.active, state.reason = false, 'external_override'
  end
end

local function install(method, make_wrapper, enabled, target)
  local state = states[method]
  target = target or vim.lsp.handlers
  if not enabled then
    restore(method)
    return
  end
  if state then
    state.active = target[method] == state.wrapper
    state.reason = not state.active and 'external_override' or nil
    return
  end
  local original = target[method]
  if type(original) ~= 'function' then return end
  local wrapper = make_wrapper(original)
  states[method] = { target = target, original = original, wrapper = wrapper, active = true }
  target[method] = wrapper
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
    if params.value.kind ~= 'begin' and params.value.kind ~= 'report' and params.value.kind ~= 'end' then
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

local function file_status_wrapper(original)
  return function(err, params, ctx, ...)
    if not config.progress or not clangd(ctx) or type(params) ~= 'table' or type(params.state) ~= 'string' then
      return original(err, params, ctx, ...)
    end
    local copy = vim.tbl_extend('force', {}, params)
    local parts = vim.split(params.state, ', ', { plain = true })
    for i, part in ipairs(parts) do parts[i] = translate('file_status', part) end
    copy.state = table.concat(parts, ', ')
    return original(err, copy, ctx, ...)
  end
end

local function hover_text(text, markdown)
  if type(text) ~= 'string' or #text > 32768 then return text end
  local lines = vim.split(text, '\n', { plain = true })
  local fence
  for i, line in ipairs(lines) do
    local marker = markdown and line:match('^%s*(```+)')
    if marker then
      if not fence then
        fence = #marker
      elseif #marker >= fence and line:match('^%s*`+%s*$') then
        fence = nil
      end
    elseif not fence then
      local heading, body = line:match('^(### )(.*)$')
      if i == 1 and heading then
        local kind, name = body:match('^([^`]-) (`.*`)$')
        if kind then
          line = heading .. translate('hover_kind', kind) .. ' ' .. name
        else
          line = heading .. translate('hover_kind', body)
        end
      elseif heading then
        line = heading .. translate('hover', body)
      elseif line == 'Parameters:' or line:match('^Type: `') or line:match('^Value = `')
        or line:match('^provided by `') or line:match('^provides `')
        or line:match('^Offset: %d') or line:match('^Size: %d') then
        line = translate('hover', line)
      end
      lines[i] = line
    end
  end
  return table.concat(lines, '\n')
end

local function hover_result(result)
  if type(result) ~= 'table' then return result end
  local contents = result.contents
  if type(contents) ~= 'table' or contents.language or type(contents.value) ~= 'string' then return result end
  local translated = hover_text(contents.value, contents.kind == 'markdown')
  if translated == contents.value then return result end
  return vim.tbl_extend('force', {}, result, {
    contents = vim.tbl_extend('force', {}, contents, { value = translated }),
  })
end

local function hover_wrapper(original)
  return function(err, result, ctx, ...)
    if config.hints and not err and clangd(ctx) then result = hover_result(result) end
    return original(err, result, ctx, ...)
  end
end

local function request_all_wrapper(original)
  return function(bufnr, method, params, handler, ...)
    if not config.hints or method ~= 'textDocument/hover' or type(handler) ~= 'function' then
      return original(bufnr, method, params, handler, ...)
    end
    return original(bufnr, method, params, function(results, ...)
      if not config.hints or type(results) ~= 'table' then return handler(results, ...) end
      local copy
      for id, response in pairs(results) do
        if type(response) == 'table' and not (response.err or response.error) and clangd({ client_id = id }) then
          local translated = hover_result(response.result)
          if translated ~= response.result then
            copy = copy or vim.tbl_extend('force', {}, results)
            copy[id] = vim.tbl_extend('force', {}, response, { result = translated })
          end
        end
      end
      return handler(copy or results, ...)
    end, ...)
  end
end

local function signature_title_wrapper(original)
  return function(lines, syntax, opts, ...)
    if config.hints and type(opts) == 'table' and opts.focus_id == 'textDocument/signatureHelp'
      and type(opts.title) == 'string' and opts.title:match('^Signature Help: clangd[ (]') then
      local title, cycle = opts.title:match('^(.-)( %(<C%-s> to cycle%))$')
      title = translate('signature_help', title or opts.title)
      if cycle then title = title .. translate('signature_help', cycle) end
      if title ~= opts.title then
        if type(lines) == 'table' and lines[1] == '# ' .. opts.title then
          lines = vim.list_slice(lines, 1)
          lines[1] = '# ' .. title
        end
        opts = vim.tbl_extend('force', {}, opts, { title = title })
      end
    end
    return original(lines, syntax, opts, ...)
  end
end

local function completion_wrapper(original)
  return function(result, prefix, client_id, ...)
    local items = original(result, prefix, client_id, ...)
    if not config.hints or not clangd({ client_id = client_id }) or type(items) ~= 'table' then return items end
    local copy
    for i, item in ipairs(items) do
      local raw = type(item) == 'table' and vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item')
      if type(raw) == 'table' then
        local menu, info = item.menu, item.info
        if menu == raw.detail and type(menu) == 'string' and menu:match('^%[%d+ overloads%]$') then
          menu = translate('completion', menu)
        end
        local doc = type(raw.documentation) == 'table' and raw.documentation.value or raw.documentation
        if info == doc and type(info) == 'string' then
          local first, rest = info:match('^([^\n]*)(.*)$')
          if first:match('^From `+.+`+$') or first:match('^From <.+>$') or first:match('^From ".+"$') then
            info = translate('completion', first) .. rest
          end
        end
        if menu ~= item.menu or info ~= item.info then
          copy = copy or vim.list_slice(items, 1)
          copy[i] = vim.tbl_extend('force', {}, item, { menu = menu, info = info })
        end
      end
    end
    return copy or items
  end
end

function M.hints_enabled() return config.hints == true end

function M.format_action(item, format_item)
  if config.hints and type(item) == 'table' and clangd(item.ctx) and type(item.action) == 'table'
    and type(item.action.title) == 'string' then
    local title = translate('code_action', item.action.title)
    if title ~= item.action.title then
      item = vim.tbl_extend('force', {}, item, {
        action = vim.tbl_extend('force', {}, item.action, { title = title }),
      })
    end
  end
  return format_item(item)
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  install('window/showMessage', message_wrapper, config.messages)
  install('window/showMessageRequest', request_wrapper, config.messages)
  install('$/progress', progress_wrapper, config.progress)
  install('textDocument/clangd.fileStatus', file_status_wrapper, config.progress)
  install('textDocument/hover', hover_wrapper, config.hints)
  install('buf_request_all', request_all_wrapper, config.hints, vim.lsp)
  install('open_floating_preview', signature_title_wrapper, config.hints, vim.lsp.util)
  -- The converter produces native popup items and retains their original LSP item in user_data.
  if vim.lsp.completion then install('_lsp_to_complete_items', completion_wrapper, config.hints, vim.lsp.completion) end
end

function M.teardown()
  config = {}
  for method in pairs(states) do restore(method) end
end
function M.info()
  local result = { messages = config.messages == true, progress = config.progress == true,
    hints = config.hints == true, logMessage = 'source', domain = 'clangd' }
  for method, state in pairs(states) do result[method] = { active = state.active == true, reason = state.reason or (state.active and 'active') or 'external_override' } end
  return result
end
return M
