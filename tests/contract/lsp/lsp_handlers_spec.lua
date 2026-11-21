local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local calls = {}
local builtin_show = vim.lsp.handlers['window/showMessage']
local builtin_request = vim.lsp.handlers['window/showMessageRequest']
local original = {}
original['window/showMessage'] = function(err, params, ctx)
  if params.message == 'boom' then error('lsp-original-error') end
  table.insert(calls, { 'show', err, params, ctx }); return 'show-return', 7
end
local actions = { { title = 'Restart' }, { title = 'Not now' } }
original['window/showMessageRequest'] = function(err, params, ctx)
  table.insert(calls, { 'request', err, params, ctx })
  return params.actions[2], 2
end
original['window/logMessage'] = function(err, params, ctx) table.insert(calls, { 'log', err, params, ctx }); return params end
original['$/progress'] = function(err, params, ctx) table.insert(calls, { 'progress', err, params, ctx }); return 'progress-return' end
original['textDocument/clangd.fileStatus'] = function(_, params) return params end
for method, fn in pairs(original) do vim.lsp.handlers[method] = fn end
local old_preview = vim.lsp.util.open_floating_preview
local upstream_complete = vim.lsp.completion._lsp_to_complete_items
vim.lsp.util.open_floating_preview = function(lines, _, opts) return lines, opts end
local overrides = { clangd = {
  show_message = { ['Indexing completed'] = '索引已完成' },
  request_message = { ['Restart clangd?'] = '重启 clangd？' },
  action = { Restart = '重启', ['Not now'] = '暂不' },
  progress_title = { Indexing = '正在索引' },
  progress_message = { ['Parsing files'] = '正在解析文件' },
} }
require('nvim-zh').setup({ modules = { ui = { notify = false, prompts = false }, plugins = { auto = false }, diagnostics = { enabled = false }, lsp = { messages = true, progress = true } }, overrides = overrides })
local old_get = vim.lsp.get_client_by_id
local capabilities = vim.lsp.protocol.make_client_capabilities()
vim.lsp.get_client_by_id = function(id)
  return {
    id = id, name = id == 1 and 'clangd' or 'other',
    capabilities = capabilities,
    server_capabilities = { completionProvider = {} },
    _get_registrations = function() return {} end,
  }
end
local err, ctx = { code = 0 }, { client_id = 1 }
local show = { type = 2, message = 'Indexing completed' }
local show_result = h.pack(vim.lsp.handlers['window/showMessage'](err, show, ctx))
equal(show_result[1], 'show-return', 'showMessage return changed')
equal(show_result[2], 7, 'showMessage second return changed')
equal(calls[1][3], show, 'custom showMessage handler lost original params')
equal(calls[1][3].type, 2, 'showMessage type changed')
equal(show.message, 'Indexing completed', 'showMessage params mutated')
local request = { type = 3, message = 'Restart clangd?', actions = actions }
local selected, index = vim.lsp.handlers['window/showMessageRequest'](err, request, ctx)
check(selected == actions[2], 'showMessageRequest did not return original action')
equal(index, 2, 'showMessageRequest original index changed')
equal(calls[2][3], request, 'custom request handler lost original params')
equal(calls[2][3].actions[1], actions[1], 'custom selector action identity changed')
equal(actions[1].title, 'Restart', 'request action mutated')
local log = { type = 4, message = 'Indexing completed' }
check(vim.lsp.handlers['window/logMessage'] == original['window/logMessage'], 'logMessage handler was wrapped')
vim.lsp.handlers['window/logMessage'](err, log, ctx)
equal(calls[3][3], log, 'logMessage params identity changed')
local progress = { token = 'fixed-token', value = { kind = 'begin', title = 'Indexing', message = 'Parsing files', percentage = 10, cancellable = true } }
equal(vim.lsp.handlers['$/progress'](err, progress, ctx), 'progress-return', 'progress return changed')
equal(calls[4][3], progress, 'progress handler lost original params')
local listeners = {}
local old_clients = vim.lsp.get_clients
vim.lsp.get_clients = function() return { { id = 1, name = 'clangd' } } end
vim.api.nvim_create_autocmd('LspProgress', { callback = function(event)
  listeners[#listeners + 1] = event.data.params
end })
vim.api.nvim_exec_autocmds('LspProgress', { pattern = 'begin', data = { client_id = 1, params = progress } })
equal(listeners[1].value.title, 'Indexing', 'progress subscriber received translation')
local display = require('nvim-zh.lsp').info().clangd_clients[1].progress
equal(display.title, '正在索引', 'panel progress title not translated')
equal(display.message, '正在解析文件', 'panel progress message not translated')
equal(display.raw.token, 'fixed-token', 'progress token changed')
local file = { uri = vim.uri_from_bufnr(0), state = 'parsing includes, file is queued' }
equal(vim.lsp.handlers['textDocument/clangd.fileStatus'](nil, file, ctx), file, 'fileStatus handler lost original params')
local display_status = require('nvim-zh.lsp').info().clangd_clients[1].file_status
equal(display_status.state, '正在解析包含的文件, 文件等待解析', 'clangd file status was not translated')
equal(display_status.raw_state, file.state, 'fileStatus raw state changed')
vim.lsp.get_clients = old_clients

local opts = { focus_id = 'textDocument/signatureHelp', title = 'Signature Help: clangd (1/2) (<C-s> to cycle)' }
local lines = { '# ' .. opts.title, 'int sum(int x, int y)' }
local preview_lines, preview_opts = vim.lsp.util.open_floating_preview(lines, 'markdown', opts)
equal(preview_opts.title, '函数签名：clangd (1/2)（按 <C-s> 切换）', 'signature title was not translated')
equal(preview_lines[1], '# ' .. preview_opts.title, 'inline signature title was not translated')
equal(preview_lines[2], lines[2], 'signature source changed')
equal(lines[1], '# ' .. opts.title, 'signature preview mutated input')

if vim.lsp.completion._lsp_to_complete_items then
  local raw = {
    label = 'sum', kind = 3, detail = '[2 overloads]', insertText = 'sum',
    documentation = { kind = 'markdown', value = 'From `<math.h>`\n\nProject docs' },
  }
  local complete = vim.lsp.completion._lsp_to_complete_items
  local item = complete({ raw }, '', 1)[1]
  local original_item = upstream_complete({ raw }, '', 1)[1]
  if vim.version().minor == 12 then
    equal(original_item.menu, raw.detail, 'pinned completion menu shape changed')
    equal(original_item.info, raw.documentation.value, 'pinned completion documentation shape changed')
  end
  local expected_menu = original_item.menu == raw.detail and '[2 个重载]' or original_item.menu
  local expected_info = original_item.info == raw.documentation.value
    and '来自 `<math.h>`\n\nProject docs' or original_item.info
  equal(item.menu, expected_menu, 'completion menu projection or fallback changed')
  equal(item.info, expected_info, 'completion documentation projection or fallback changed')
  equal(item.word, 'sum', 'completion insertion text changed')
  equal(item.user_data.nvim.lsp.completion_item, raw, 'completion protocol item identity changed')
  equal(raw.detail, '[2 overloads]', 'completion protocol item mutated')
  equal(complete({ raw }, '', 2)[1].menu, original_item.menu, 'other server completion translated')
end
local boom_ok, boom_err = pcall(vim.lsp.handlers['window/showMessage'], err, { type = 2, message = 'boom' }, ctx)
check(not boom_ok and tostring(boom_err):find('lsp-original-error', 1, true), 'LSP original exception swallowed')
local unknown = { type = 2, message = 'Unknown message' }
vim.lsp.handlers['window/showMessage'](err, unknown, ctx)
equal(calls[#calls][3].message, 'Unknown message', 'unknown message changed')
local original_show = vim.lsp.handlers['window/showMessage']
require('nvim-zh').setup({ modules = { diagnostics = { enabled = false }, lsp = { messages = true, progress = true } }, overrides = overrides })
equal(vim.lsp.handlers['window/showMessage'], original_show, 'handler duplicated on setup')
vim.lsp.handlers['window/showMessage'] = builtin_show
vim.lsp.handlers['window/showMessageRequest'] = builtin_request
local adapter = require('nvim-zh.lsp')
adapter.setup({ messages = true, progress = true })
local old_notify, old_select = vim.notify, vim.ui.select
vim.notify = function(message) equal(message, 'LSP[clangd] 索引已完成', 'built-in notification text') end
equal(vim.lsp.handlers['window/showMessage'](nil, show, ctx), show, 'built-in notification result')
vim.notify = old_notify
local returned
vim.ui.select = function(items, options, choice)
  equal(items, actions, 'built-in selection actions were copied')
  equal(options.format_item(items[1]), '重启', 'built-in selection label')
  choice(items[2], 2)
end
local thread = coroutine.create(function()
  returned = vim.lsp.handlers['window/showMessageRequest'](nil, request, ctx)
end)
assert(coroutine.resume(thread))
assert(vim.wait(1000, function() return returned ~= nil end))
equal(returned, actions[2], 'built-in selection returned a different action')
vim.ui.select = old_select
equal(adapter.info()['window/showMessage'].reason, 'active', 'owned handler reported external replacement')
local external = function() return 'external' end
vim.lsp.handlers['window/showMessage'] = external
dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
equal(vim.lsp.handlers['window/showMessage'], external, 'reload reclaimed external handler')
require('nvim-zh.lsp').teardown()
equal(vim.lsp.handlers['window/showMessage'], external, 'teardown reclaimed external handler')
require('nvim-zh.lsp').setup({ messages = true, progress = true })
equal(vim.lsp.handlers['window/showMessage'], external, 'teardown/re-enable reclaimed external handler')
equal(require('nvim-zh.lsp').info()['window/showMessage'].reason, 'external_override', 'external handler ownership forgotten')
require('nvim-zh.lsp').teardown()
vim.lsp.get_client_by_id = old_get
vim.lsp.util.open_floating_preview = old_preview
print('LSP_HANDLER_SPEC=PASS original_action token cancellation log_source unknown_fallback')
