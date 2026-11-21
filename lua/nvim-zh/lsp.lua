local M = {}
local engine = require('nvim-zh.engine')
local missing = require('nvim-zh.missing')
local packs = require('nvim-zh.packs')
local config = {}
local states = {}
local file_status, progress = {}, {}
local scope
local evidence = require('nvim-zh.adapters.evidence')
local handlers_source, buf_source
local file_status_method = 'textDocument/clangd.fileStatus'

local function clangd(ctx, method)
  if type(ctx) ~= 'table' or type(ctx.client_id) ~= 'number' then return false end
  local ok, client = pcall(vim.lsp.get_client_by_id, ctx.client_id)
  return ok and type(client) == 'table' and client.name == 'clangd' and packs.tool_allows('clangd', client, method)
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

local function install(method, make_wrapper, enabled, target, source)
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
  if source and debug.getinfo(original, 'S').source ~= source then return end
  local project = make_wrapper(original)
  local wrapper
  wrapper = function(...)
    if target[method] == wrapper then return project(...) end
    return original(...)
  end
  states[method] = { target = target, original = original, wrapper = wrapper, active = true }
  target[method] = wrapper
end

local function show_message(params, ctx, message)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  vim.notify(('LSP[%s] %s'):format(client.name, message), vim.lsp.log._from_lsp_level(params.type))
end

local function message_wrapper(original)
  return function(err, params, ctx, ...)
    if not config.messages or err or not clangd(ctx, 'window/showMessage')
      or type(params) ~= 'table' or type(params.message) ~= 'string' then
      return original(err, params, ctx, ...)
    end
    show_message(params, ctx, translate('show_message', params.message))
    return params
  end
end

local function request_wrapper(original)
  return function(err, params, ctx, ...)
    if not config.messages or err or not clangd(ctx, 'window/showMessageRequest')
      or type(params) ~= 'table' or type(params.message) ~= 'string' then
      return original(err, params, ctx, ...)
    end
    local message = translate('request_message', params.message)
    local actions = params.actions or {}
    if not next(actions) then
      show_message(params, ctx, message)
      return vim.NIL
    end
    local function title(action)
      return (translate('action', action.title):gsub('\r\n', '\\r\\n'):gsub('\n', '\\n'))
    end
    local co, is_main = coroutine.running()
    if co and not is_main then
      vim.ui.select(actions, { kind = 'lsp_message', prompt = message .. ': ', format_item = title }, function(choice)
        vim.schedule(function() coroutine.resume(co, choice or vim.NIL) end)
      end)
      return coroutine.yield()
    end
    local lines = { message, '\nRequest Actions:' }
    for i, action in ipairs(actions) do lines[#lines + 1] = ('%d. %s'):format(i, title(action)) end
    return actions[vim.fn.inputlist(lines)] or vim.NIL
  end
end

local function display_changed()
  require('nvim-zh.runtime').changed('adapters')
end

local function project_progress(id, record)
  local value = record.raw.value
  record.title, record.message = value.title, value.message
  if clangd({ client_id = id }, '$/progress') then
    record.title = translate('progress_title', value.title)
    record.message = translate('progress_message', value.message)
  end
end

local function project_file(id, record)
  record.state = record.raw_state
  if not clangd({ client_id = id }, file_status_method) then return end
  local parts = vim.split(record.raw_state, ', ', { plain = true })
  for i, part in ipairs(parts) do parts[i] = translate('file_status', part) end
  record.state = table.concat(parts, ', ')
end

function M.refresh_display()
  for id, record in pairs(progress) do project_progress(id, record) end
  for id, files in pairs(file_status) do
    for _, record in pairs(files) do project_file(id, record) end
  end
end

local function progress_event(event)
  local data = event.data
  local params = data and data.params
  local value = params and params.value
  local client = data and vim.lsp.get_client_by_id(data.client_id)
  if type(value) ~= 'table' or not client or client.name ~= 'clangd' then return end
  if value.kind ~= 'begin' and value.kind ~= 'report' and value.kind ~= 'end' then return end
  local record = { raw = vim.deepcopy(params) }
  project_progress(data.client_id, record)
  progress[data.client_id] = record
  display_changed()
end

local function file_status_wrapper(original)
  return function(err, params, ctx, ...)
    local client = type(ctx) == 'table' and vim.lsp.get_client_by_id(ctx.client_id)
    if config.progress and not err and client and client.name == 'clangd' and type(params) == 'table'
      and type(params.uri) == 'string' and type(params.state) == 'string' then
      local files = file_status[ctx.client_id] or {}
      local record = { uri = params.uri, raw_state = params.state }
      project_file(ctx.client_id, record)
      files[params.uri] = record
      file_status[ctx.client_id] = files
      vim.schedule(display_changed)
    end
    return original(err, params, ctx, ...)
  end
end

local function hover_text(text, markdown)
  if not markdown or type(text) ~= 'string' or #text > 32768 then return text end
  -- clangd writes this heading before emitting any comment or definition.
  -- The remaining markdown has no boundary between generated fields and docs.
  local kind, name, rest = text:match('^### ([^`\n]-) (`[^\n]*`)(\n.*)$')
  if not kind then return text end
  return '### ' .. translate('hover_kind', kind) .. ' ' .. name .. rest
end

local function preview_wrapper(original)
  return function(lines, syntax, opts, ...)
    if config.hints and type(opts) == 'table' and opts.focus_id == 'textDocument/hover'
      and syntax == 'markdown' and type(lines) == 'table' and type(lines[1]) == 'string' then
      -- install() invokes this projection through one tail call. Only the
      -- fixed built-in renderer establishes which client produced the heading.
      local caller = debug.getinfo(2, 'S')
      if caller and caller.source == buf_source then
        local clients = vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/hover' })
        local client = #clients == 1 and clients[1]
        if client and client.name == 'clangd' and packs.tool_allows('clangd', client, 'textDocument/hover') then
          local text = hover_text(lines[1] .. '\n', true):sub(1, -2)
          if text ~= lines[1] then
            lines = vim.list_slice(lines, 1)
            lines[1] = text
          end
        end
      end
    end
    if config.hints and type(opts) == 'table' and opts.focus_id == 'textDocument/signatureHelp'
      and type(opts.title) == 'string' and opts.title:match('^Signature Help: clangd[ (]') then
      local clients = vim.lsp.get_clients({ bufnr = 0, name = 'clangd' })
      if #clients > 1 or not packs.tool_allows('clangd', clients[1], 'textDocument/signatureHelp') then
        return original(lines, syntax, opts, ...)
      end
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
    if not config.hints or not clangd({ client_id = client_id }, 'textDocument/completion') or type(items) ~= 'table' then return items end
    local client = vim.lsp.get_client_by_id(client_id)
    local reviewed = packs.tool_reason('clangd', client, 'textDocument/completion') == 'verified'
    local copy
    local labels = {}
    local function label(text)
      local cached = labels[text]
      if not cached then
        local value, status = engine.translate({ domain = 'clangd', context = 'completion', msgid = text,
          formatted = true, observe = false })
        cached = { text = value, status = status }
        labels[text] = cached
      end
      if cached.text ~= text or cached.status == 'fallback' then
        missing.observe({ domain = 'clangd', context = 'completion', msgid = text, dynamic = true,
          translated = cached.status == 'translated' })
      end
      return cached.text
    end
    for i, item in ipairs(items) do
      local raw = type(item) == 'table' and vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item')
      if type(raw) == 'table' then
        local menu, info = item.menu, item.info
        if menu == raw.detail and type(menu) == 'string' and menu:match('^%[%d+ overloads%]$') then
          menu = label(menu)
        end
        local doc = type(raw.documentation) == 'table' and raw.documentation.value or raw.documentation
        if info == doc and type(info) == 'string' then
          local first, rest = info:match('^([^\n]*)(.*)$')
          local header = first:match('^From `+(.-)`+$') or first:match('^From (<.+>)$') or first:match('^From (".+")$')
          -- clangd places both documentation and include information in the
          -- same string. A corresponding insertion establishes header origin.
          if header and (not reviewed or vim.iter(raw.additionalTextEdits or {}):any(function(edit)
            return type(edit.newText) == 'string' and edit.newText:find('#include ' .. header, 1, true)
          end)) then
            info = label(first) .. rest
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
  local text = format_item(item)
  if not config.hints or type(text) ~= 'string' or not buf_source
    or debug.getinfo(format_item, 'S').source ~= buf_source or type(item) ~= 'table'
    or type(item.action) ~= 'table' or type(item.action.title) ~= 'string'
    or not clangd(item.ctx, 'textDocument/codeAction') then return text end
  local function escape(title)
    return title:gsub('\r\n', '\\r\\n'):gsub('\n', '\\n')
  end
  local original = escape(item.action.title)
  if text:sub(1, #original) ~= original then return text end
  return escape(translate('code_action', item.action.title)) .. text:sub(#original + 1)
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  if config.messages and handlers_source == nil then
    handlers_source = evidence.runtime_source('lsp/handlers.lua',
      'f2b4671ac7267dbecfe695848e7f370cfc938459259bbfb80e94be94b2863c57') or false
  end
  if config.hints and buf_source == nil then
    buf_source = evidence.runtime_source('lsp/buf.lua',
      '481c8133ba7977e9c7f8103122d797ba362cfc6ec246f0f4d76c0b8338ce01a9') or false
  end
  install('window/showMessage', message_wrapper, config.messages and handlers_source, nil, handlers_source)
  install('window/showMessageRequest', request_wrapper, config.messages and handlers_source, nil, handlers_source)
  if (config.progress or config.hints) and not scope then
    scope = require('nvim-zh.adapters.scope').new(function() return config.progress or config.hints end)
    scope.autocmd('LspAttach', { callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client.name == 'clangd' then
        packs.ensure_tool('clangd', true)
        vim.schedule(display_changed)
      end
    end })
    scope.autocmd('LspProgress', { callback = function(event)
      if config.progress then progress_event(event) end
    end })
    scope.autocmd('LspDetach', { callback = function(event)
      local id = event.data.client_id
      local files = file_status[id]
      if files then files[vim.uri_from_bufnr(event.buf)] = nil end
      vim.schedule(function()
        if not vim.lsp.get_client_by_id(id) then file_status[id], progress[id] = nil, nil end
        display_changed()
      end)
    end })
  elseif not (config.progress or config.hints) and scope then
    scope.close()
    scope = nil
    file_status, progress = {}, {}
  end
  if not config.progress then file_status, progress = {}, {} end
  if config.progress and not vim.lsp.handlers[file_status_method] and not states[file_status_method] then
    local wrapper = file_status_wrapper(function() end)
    states[file_status_method] = { target = vim.lsp.handlers, wrapper = wrapper, active = true }
    vim.lsp.handlers[file_status_method] = wrapper
  else
    install(file_status_method, file_status_wrapper, config.progress)
  end
  M.refresh_display()
  install('open_floating_preview', preview_wrapper, config.hints, vim.lsp.util)
  -- The converter produces native popup items and retains their original LSP item in user_data.
  if vim.lsp.completion then install('_lsp_to_complete_items', completion_wrapper, config.hints, vim.lsp.completion) end
end

function M.teardown()
  M.setup({})
  for method in pairs(states) do restore(method) end
end
function M.info(bufnr)
  local result = { messages = config.messages == true, progress = config.progress == true,
    hints = config.hints == true, logMessage = 'source', domain = 'clangd', clangd_clients = {} }
  if config.messages then
    for _, method in ipairs({ 'window/showMessage', 'window/showMessageRequest' }) do
      result[method] = { active = false, reason = handlers_source and 'external_override' or 'unsupported_interface' }
    end
  end
  result['$/progress'] = { active = config.progress == true and scope ~= nil, reason = config.progress and 'active' or 'disabled' }
  local buf = bufnr or vim.api.nvim_get_current_buf()
  local uri = vim.uri_from_bufnr(buf)
  local clients = vim.lsp.get_clients({ bufnr = buf, name = 'clangd' })
  if #clients == 0 then clients = vim.lsp.get_clients({ name = 'clangd' }) end
  for _, client in ipairs(clients) do
    local files = file_status[client.id]
    local methods = {}
    for _, method in ipairs({ 'textDocument/publishDiagnostics', 'textDocument/diagnostic', 'textDocument/hover',
      'textDocument/codeAction', 'textDocument/completion', 'textDocument/signatureHelp', '$/progress', file_status_method }) do
      methods[method] = packs.tool_reason('clangd', client, method)
    end
    result.clangd_clients[#result.clangd_clients + 1] = {
      id = client.id, bufnr = buf, attached = client.attached_buffers and client.attached_buffers[buf] == true,
      version = client.server_info and client.server_info.version,
      reason = methods['textDocument/publishDiagnostics'], methods = methods,
      file_status = vim.deepcopy(files and files[uri]),
      progress = vim.deepcopy(progress[client.id]),
    }
  end
  for method, state in pairs(states) do result[method] = { active = state.active == true, reason = state.reason or (state.active and 'active') or 'external_override' } end
  return result
end
return M
