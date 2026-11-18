local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local calls = {}
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
for method, fn in pairs(original) do vim.lsp.handlers[method] = fn end
local overrides = { clangd = {
  show_message = { ['Indexing completed'] = '索引已完成' },
  request_message = { ['Restart clangd?'] = '重启 clangd？' },
  action = { Restart = '重启', ['Not now'] = '暂不' },
  progress_title = { Indexing = '正在索引' },
  progress_message = { ['Parsing files'] = '正在解析文件' },
} }
require('nvim-zh').setup({ modules = { ui = { notify = false, prompts = false }, plugins = { auto = false }, diagnostics = { enabled = false }, lsp = { messages = true, progress = true } }, overrides = overrides })
local old_get = vim.lsp.get_client_by_id
vim.lsp.get_client_by_id = function(id) return { id = id, name = 'clangd' } end
local err, ctx = { code = 0 }, { client_id = 1 }
local show = { type = 2, message = 'Indexing completed' }
local show_result = h.pack(vim.lsp.handlers['window/showMessage'](err, show, ctx))
equal(show_result[1], 'show-return', 'showMessage return changed')
equal(show_result[2], 7, 'showMessage second return changed')
equal(calls[1][3].message, '索引已完成', 'showMessage display not translated')
equal(calls[1][3].type, 2, 'showMessage type changed')
equal(show.message, 'Indexing completed', 'showMessage params mutated')
local request = { type = 3, message = 'Restart clangd?', actions = actions }
local selected, index = vim.lsp.handlers['window/showMessageRequest'](err, request, ctx)
check(selected == actions[2], 'showMessageRequest did not return original action')
equal(index, 2, 'showMessageRequest original index changed')
equal(calls[2][3].message, '重启 clangd？', 'request display message not translated')
equal(calls[2][3].actions[1].title, '重启', 'request action display not translated')
equal(actions[1].title, 'Restart', 'request action mutated')
local log = { type = 4, message = 'Indexing completed' }
check(vim.lsp.handlers['window/logMessage'] == original['window/logMessage'], 'logMessage handler was wrapped')
vim.lsp.handlers['window/logMessage'](err, log, ctx)
equal(calls[3][3], log, 'logMessage params identity changed')
local progress = { token = 'fixed-token', value = { kind = 'begin', title = 'Indexing', message = 'Parsing files', percentage = 10, cancellable = true } }
equal(vim.lsp.handlers['$/progress'](err, progress, ctx), 'progress-return', 'progress return changed')
local shown_progress = calls[4][3]
equal(shown_progress.value.title, '正在索引', 'progress title not translated')
equal(shown_progress.value.message, '正在解析文件', 'progress message not translated')
equal(shown_progress.token, 'fixed-token', 'progress token changed')
equal(shown_progress.value.percentage, 10, 'progress percentage changed')
equal(shown_progress.value.cancellable, true, 'progress cancellable changed')
equal(progress.value.title, 'Indexing', 'progress params mutated')
local boom_ok, boom_err = pcall(vim.lsp.handlers['window/showMessage'], err, { type = 2, message = 'boom' }, ctx)
check(not boom_ok and tostring(boom_err):find('lsp-original-error', 1, true), 'LSP original exception swallowed')
local unknown = { type = 2, message = 'Unknown message' }
vim.lsp.handlers['window/showMessage'](err, unknown, ctx)
equal(calls[#calls][3].message, 'Unknown message', 'unknown message changed')
local original_show = vim.lsp.handlers['window/showMessage']
require('nvim-zh').setup({ modules = { diagnostics = { enabled = false }, lsp = { messages = true, progress = true } }, overrides = overrides })
equal(vim.lsp.handlers['window/showMessage'], original_show, 'handler duplicated on setup')
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
print('LSP_HANDLER_SPEC=PASS original_action token cancellation log_source unknown_fallback')
