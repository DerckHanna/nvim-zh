local M = {}
local engine = require('nvim-zh.engine')
local missing = require('nvim-zh.missing')
local packs = require('nvim-zh.packs')
local config = {}
local states = {}
local file_status, progress = {}, {}
local signatures = setmetatable({}, { __mode = 'k' })
local sequence = 0
local scope
local evidence = require('nvim-zh.adapters.evidence')
local handlers_source, buf_source, util_source
local file_status_method = 'textDocument/clangd.fileStatus'

local function attached(client, buf)
  return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf) and client.attached_buffers
    and client.attached_buffers[buf] ~= nil
end

local function clangd(ctx, method)
  if type(ctx) ~= 'table' or type(ctx.client_id) ~= 'number' then return false end
  local ok, client = pcall(vim.lsp.get_client_by_id, ctx.client_id)
  return ok and type(client) == 'table' and client.name == 'clangd'
    and (not ctx.bufnr or attached(client, ctx.bufnr))
    and packs.tool_allows('clangd', client, method, ctx.bufnr)
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
  for id, state in pairs(progress) do
    if state.latest then project_progress(id, state.latest) end
    for _, record in pairs(state.tokens) do
      if record ~= state.latest then project_progress(id, record) end
    end
  end
  for id, files in pairs(file_status) do
    for _, record in pairs(files) do project_file(id, record) end
  end
end

local function prune_client(id)
  local client = vim.lsp.get_client_by_id(id)
  if not client or (client.is_stopped and client:is_stopped()) or not next(client.attached_buffers or {}) then
    file_status[id], progress[id] = nil, nil
  end
end

local function progress_event(event)
  local data = event.data
  local params = data and data.params
  local value = params and params.value
  local client = data and vim.lsp.get_client_by_id(data.client_id)
  if type(value) ~= 'table' or not client or client.name ~= 'clangd' or not next(client.attached_buffers or {}) then return end
  if value.kind ~= 'begin' and value.kind ~= 'report' and value.kind ~= 'end' then return end
  local token = params.token
  if type(token) ~= 'string' and type(token) ~= 'number' then return end
  local state = progress[client.id]
  if not state or state.client ~= client then
    state = { client = client, tokens = {} }
    progress[client.id] = state
  end
  if value.kind == 'end' and not state.tokens[token] then return end
  sequence = sequence + 1
  local record = { raw = vim.deepcopy(params), sequence = sequence }
  project_progress(data.client_id, record)
  if value.kind == 'end' then state.tokens[token] = nil else state.tokens[token] = record end
  state.latest = record
  display_changed()
end

local function clear_buffer(buf)
  for id, files in pairs(file_status) do
    files[buf] = nil
    if not next(files) then file_status[id] = nil end
  end
  for opts, origin in pairs(signatures) do
    if origin == buf then signatures[opts] = nil end
  end
end

local function file_status_wrapper(original)
  return function(err, params, ctx, ...)
    local client = type(ctx) == 'table' and vim.lsp.get_client_by_id(ctx.client_id)
    if config.progress and not err and client and client.name == 'clangd' and type(params) == 'table'
      and type(params.uri) == 'string' and type(params.state) == 'string' then
      -- clangd and Neovim use different case for percent escapes in filenames.
      local uri = params.uri:gsub('%%%x%x', string.upper)
      for buf in pairs(client.attached_buffers or {}) do
        if attached(client, buf) and vim.uri_from_bufnr(buf):gsub('%%%x%x', string.upper) == uri then
          local files = file_status[ctx.client_id] or {}
          local record = { uri = params.uri, raw_state = params.state }
          project_file(ctx.client_id, record)
          files[buf] = record
          file_status[ctx.client_id] = files
          vim.schedule(display_changed)
          break
        end
      end
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

-- These locals are used only at the pinned Neovim display call sites. Upstream
-- aggregates replies and retains their raw values for other consumers.
local function local_value(level, name)
  local index = 1
  while true do
    local key, value = debug.getlocal(level + 1, index)
    if not key or key == name then return value end
    index = index + 1
  end
end

local function upvalue(fn, name)
  local index = 1
  while true do
    local key, value = debug.getupvalue(fn, index)
    if not key or key == name then return key == name, value end
    index = index + 1
  end
end

local function hover_wrapper(original)
  return function(input, ...)
    local caller = debug.getinfo(2, 'Sl')
    if not config.hints or not caller or caller.source ~= buf_source or caller.currentline ~= 163
      or type(input) ~= 'table' or input.kind ~= 'markdown' then return original(input, ...) end
    local client = local_value(2, 'client')
    local buf = local_value(2, 'bufnr')
    if type(client) ~= 'table' or type(buf) ~= 'number'
      or not clangd({ client_id = client.id, bufnr = buf }, 'textDocument/hover') then return original(input, ...) end
    local text = hover_text(input.value, true)
    if text == input.value then return original(input, ...) end
    return original(vim.tbl_extend('force', {}, input, { value = text }), ...)
  end
end

local function preview_wrapper(original)
  return function(lines, syntax, opts, ...)
    local caller = debug.getinfo(2, 'fSl')
    if not config.hints or not caller or caller.source ~= buf_source or caller.currentline ~= 471
      or type(opts) ~= 'table' or opts.focus_id ~= 'textDocument/signatureHelp' or type(opts.title) ~= 'string' then
      return original(lines, syntax, opts, ...)
    end
    local client = local_value(2, 'client')
    local found_title, user_title = upvalue(caller.func, 'user_title')
    local parent = debug.getinfo(3, 'Sl')
    if parent and parent.source == buf_source and parent.currentline == 486 then
      local ctx = local_value(3, 'ctx')
      if ctx then signatures[opts] = ctx.bufnr end
    end
    local buf = signatures[opts]
    if not found_title or user_title ~= nil or type(client) ~= 'table' or not buf
      or not clangd({ client_id = client.id, bufnr = buf }, 'textDocument/signatureHelp') then
      return original(lines, syntax, opts, ...)
    end
    local title, cycle = opts.title:match('^(.-)( %(<C%-s> to cycle%))$')
    title = translate('signature_help', title or opts.title)
    if cycle then title = title .. translate('signature_help', cycle) end
    if title == opts.title then return original(lines, syntax, opts, ...) end
    if type(lines) == 'table' and lines[1] == '# ' .. opts.title then
      lines = vim.list_slice(lines, 1)
      lines[1] = '# ' .. title
    end
    return original(lines, syntax, vim.tbl_extend('force', {}, opts, { title = title }), ...)
  end
end

local function completion_documentation(event)
  local item = vim.v.event.completed_item
  local origin = vim.tbl_get(item or {}, 'user_data', 'nvim', 'lsp')
  local raw = origin and origin.completion_item
  local doc = raw and raw.documentation
  doc = type(doc) == 'table' and doc.value or doc
  if type(doc) ~= 'string' or item.info ~= doc or type(origin.client_id) ~= 'number' then return end
  local first = doc:match('^[^\n]+')
  local header = first and (first:match('^From `+(.-)`+$') or first:match('^From (<.+>)$') or first:match('^From (".+")$'))
  if not header or not vim.iter(raw.additionalTextEdits or {}):any(function(edit)
    return type(edit.newText) == 'string' and edit.newText:find('#include ' .. header, 1, true)
  end) then return end
  local buf = event.buf
  local client = vim.lsp.get_client_by_id(origin.client_id)
  if not client or client.name ~= 'clangd' or not attached(client, buf)
    or packs.tool_reason('clangd', client, 'textDocument/completion', buf) ~= 'verified' then return end
  local current_scope = scope
  vim.schedule(function()
    if scope ~= current_scope or not config.hints or vim.api.nvim_get_current_buf() ~= buf
      or vim.lsp.get_client_by_id(client.id) ~= client or not attached(client, buf)
      or packs.tool_reason('clangd', client, 'textDocument/completion', buf) ~= 'verified' then return end
    local info = vim.fn.complete_info({ 'completed', 'selected' })
    local selected = info.completed
    if not selected or selected.word ~= item.word or selected.info ~= doc
      or not vim.deep_equal(vim.tbl_get(selected, 'user_data', 'nvim', 'lsp'), origin) then return end
    local preview = info.preview_bufnr
    if type(preview) ~= 'number' or preview <= 0 or not vim.api.nvim_buf_is_valid(preview)
      or not vim.bo[preview].modifiable or vim.api.nvim_buf_get_lines(preview, 0, 1, false)[1] ~= first then return end
    local display = translate('completion', first)
    if display ~= first then vim.api.nvim_buf_set_lines(preview, 0, 1, false, { display }) end
  end)
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
    util_source = evidence.runtime_source('lsp/util.lua',
      '22179bbf8a8fd11f2b2c275d5d3641558ff5c037de2227ddd4766a19ad9bd5dd') or false
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
    scope.autocmd('CompleteChanged', { callback = function(event)
      if config.hints then completion_documentation(event) end
    end })
    scope.autocmd('LspDetach', { callback = function(event)
      local id = event.data.client_id
      local files = file_status[id]
      if files then
        files[event.buf] = nil
        if not next(files) then file_status[id] = nil end
      end
      local current_scope = scope
      vim.schedule(function()
        if scope ~= current_scope then return end
        prune_client(id)
        display_changed()
      end)
    end })
    scope.autocmd({ 'BufFilePost', 'BufWipeout' }, { callback = function(event)
      clear_buffer(event.buf)
      if event.event == 'BufWipeout' then
        local current_scope = scope
        vim.schedule(function()
          if scope == current_scope then
            for id in pairs(progress) do prune_client(id) end
          end
        end)
      end
    end })
    scope.autocmd('BufEnter', { callback = function()
      for id in pairs(progress) do prune_client(id) end
    end })
  elseif not (config.progress or config.hints) and scope then
    scope.close()
    scope = nil
    file_status, progress = {}, {}
  end
  if not config.progress then file_status, progress = {}, {} end
  if not config.hints then signatures = setmetatable({}, { __mode = 'k' }) end
  if config.progress and not vim.lsp.handlers[file_status_method] and not states[file_status_method] then
    local wrapper = file_status_wrapper(function() end)
    states[file_status_method] = { target = vim.lsp.handlers, wrapper = wrapper, active = true }
    vim.lsp.handlers[file_status_method] = wrapper
  else
    install(file_status_method, file_status_wrapper, config.progress)
  end
  M.refresh_display()
  install('open_floating_preview', preview_wrapper, config.hints and buf_source and util_source, vim.lsp.util, util_source)
  install('convert_input_to_markdown_lines', hover_wrapper,
    config.hints and buf_source and util_source, vim.lsp.util, util_source)
end

function M.teardown()
  M.setup({})
  for method in pairs(states) do restore(method) end
end
function M.info(bufnr)
  local result = { messages = config.messages == true, progress = config.progress == true,
    hints = config.hints == true, logMessage = 'source', domain = 'clangd',
    clangd_clients = {}, background_clangd_clients = {} }
  if config.messages then
    for _, method in ipairs({ 'window/showMessage', 'window/showMessageRequest' }) do
      result[method] = { active = false, reason = handlers_source and 'external_override' or 'unsupported_interface' }
    end
  end
  result['$/progress'] = { active = config.progress == true and scope ~= nil, reason = config.progress and 'active' or 'disabled' }
  local buf = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ name = 'clangd' })
  table.sort(clients, function(a, b) return a.id < b.id end)
  for _, client in ipairs(clients) do
    local files = file_status[client.id]
    local here = not not attached(client, buf)
    local state = progress[client.id]
    local tokens = state and state.client == client and vim.tbl_values(state.tokens) or {}
    table.sort(tokens, function(a, b) return a.sequence > b.sequence end)
    local methods = {}
    for _, method in ipairs({ 'textDocument/publishDiagnostics', 'textDocument/diagnostic', 'textDocument/hover',
      'textDocument/codeAction', 'textDocument/completion', 'textDocument/signatureHelp', '$/progress', file_status_method }) do
      methods[method] = packs.tool_reason('clangd', client, method, here and buf or nil)
    end
    if here and client.handlers and client.handlers[file_status_method] then
      methods[file_status_method] = 'external_override'
    end
    local rows = here and result.clangd_clients or result.background_clangd_clients
    rows[#rows + 1] = {
      id = client.id, bufnr = buf, attached = here,
      version = client.server_info and client.server_info.version,
      reason = methods['textDocument/publishDiagnostics'], methods = methods,
      file_status = vim.deepcopy(here and files and files[buf] or nil),
      progress = vim.deepcopy(tokens[1] or state and state.client == client and state.latest or nil),
      progress_tokens = vim.deepcopy(tokens),
    }
  end
  for method, state in pairs(states) do result[method] = { active = state.active == true, reason = state.reason or (state.active and 'active') or 'external_override' } end
  return result
end
return M
