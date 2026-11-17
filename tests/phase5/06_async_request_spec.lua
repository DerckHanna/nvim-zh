local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase5/helpers.lua')
local check, equal = h.check, h.equal
local actions = { { title = 'Restart' }, { title = 'Not now' } }
local params = { type = 3, message = 'Restart clangd?', actions = actions }
local old_get, old_select = vim.lsp.get_client_by_id, vim.ui.select
vim.lsp.get_client_by_id = function(id) return { id = id, name = 'clangd' } end
local order = {}
vim.ui.select = function(items, opts, callback)
  table.insert(order, 'select')
  check(items ~= actions and items[1] ~= actions[1], 'request did not isolate display actions')
  vim.schedule(function()
    table.insert(order, 'callback')
    callback(items[1], 1)
  end)
end
require('nvim-zh').setup({
  modules = { ui = { notify = false, prompts = false }, plugins = { auto = false }, diagnostics = { enabled = false }, lsp = { messages = true, progress = false } },
  overrides = { clangd = { request_message = { ['Restart clangd?'] = '重启 clangd？' }, action = { Restart = '重启', ['Not now'] = '暂不' } } },
})
local selected
local co = coroutine.create(function()
  table.insert(order, 'handler-start')
  selected = vim.lsp.handlers['window/showMessageRequest'](nil, params, { client_id = 77 })
  table.insert(order, 'handler-end')
end)
check(coroutine.resume(co), 'async request coroutine failed')
check(vim.wait(1000, function() return selected ~= nil end), 'async request did not resume')
check(selected == actions[1], 'async request returned translated action instead of original')
equal(table.concat(order, ','), 'handler-start,select,callback,handler-end', 'async request order changed')
equal(params.message, 'Restart clangd?', 'async request mutated source params')
equal(actions[1].title, 'Restart', 'async request mutated source action')
vim.lsp.get_client_by_id, vim.ui.select = old_get, old_select
print('ASYNC_REQUEST_SPEC=PASS original_action async_order=identical')
