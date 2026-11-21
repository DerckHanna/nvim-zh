local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local packs, lsp = require('nvim-zh.packs'), require('nvim-zh.lsp')
local buf = vim.api.nvim_get_current_buf()
local other_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, vim.env.NVIM_ZH_TMP .. '/甲.cpp')
vim.api.nvim_buf_set_name(other_buf, vim.env.NVIM_ZH_TMP .. '/b.cpp')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'int x;' })
local one_ns, one = h.client(buf, { id = 9001 })
local two_ns, two = h.client(buf, { id = 9002, attached_buffers = { [buf] = 'cpp', [other_buf] = 'cpp' } })
local other_ns, other = h.client(buf, { id = 9003, name = 'other' })
for _, client in ipairs({ one, two, other }) do
  client.offset_encoding, client.server_capabilities = 'utf-16', {}
end
local reason, get_clients = packs.tool_reason, vim.lsp.get_clients
packs.tool_reason = function(id, client, ...)
  if id == 'clangd' and client then return client == one and 'verified' or 'unsupported_version' end
  return reason(id, client, ...)
end
vim.lsp.get_clients = function(filter)
  return vim.tbl_filter(function(client)
    return (not filter.name or client.name == filter.name)
      and (not filter.bufnr or client.attached_buffers[filter.bufnr])
  end, { one, two, other })
end
vim.diagnostic.config({ virtual_text = true, virtual_lines = true, float = true })
h.setup()
packs.prepare_domain('clangd')
local known = "Redefinition of 'x'"
for _, ns in ipairs({ one_ns, two_ns, other_ns }) do
  vim.diagnostic.set(ns, buf, { { lnum = 0, col = ns == one_ns and 0 or ns == two_ns and 1 or 2,
    severity = 1, source = 'clangd', message = known } })
end
local function count(str, plain)
  local n, offset = 0, 1
  while true do
    local first, last = str:find(plain, offset, true)
    if not first then return n end
    n, offset = n + 1, last + 1
  end
end
local text, lines = '', ''
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
  for _, chunk in ipairs(mark[4].virt_text or {}) do text = text .. chunk[1] end
  for _, line in ipairs(mark[4].virt_lines or {}) do
    for _, chunk in ipairs(line) do lines = lines .. chunk[1] end
  end
end
for _, shown in ipairs({ text, lines }) do
  h.equal(count(shown, '重复定义'), 1, 'verified virtual diagnostic isolation')
  h.equal(count(shown, known), 2, 'other virtual namespaces translated')
end
local fbuf, fwin = vim.diagnostic.open_float({ scope = 'buffer' })
local float = table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), '\n')
h.equal(count(float, '重复定义'), 1, 'verified float isolation')
h.equal(count(float, known), 2, 'other float namespaces translated')
vim.api.nvim_win_close(fwin, true)
vim.diagnostic.setqflist({ open = true })
for _, row in ipairs(vim.fn.getqflist()) do h.equal(row.text, known, 'quickfix changed raw text') end
local qf = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
h.equal(count(qf, '重复定义'), 1, 'verified list isolation')
vim.cmd.cclose()
local owner = vim.api.nvim_get_current_win()
vim.diagnostic.setloclist({ winnr = owner, open = true })
local loc = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
h.equal(count(loc, '重复定义'), 1, 'verified loclist isolation')
vim.cmd.lclose()

local request_all = vim.lsp.buf_request_all
local responses = {}
for _, client in ipairs({ one, two, other }) do
  responses[client.id] = {
    result = { contents = { kind = 'markdown', value = '### function `owned_' .. client.id .. '`\n\nproject text' } },
  }
end
local original = vim.deepcopy(responses)
vim.lsp.buf_request_all = function(_, method, _, callback)
  h.equal(method, 'textDocument/hover', 'unexpected request during hover')
  callback(responses, { bufnr = buf, version = vim.lsp.util.buf_versions[buf] })
  return function() end
end
vim.lsp.buf.hover()
local hover, hover_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    hover_win = win
    hover = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    break
  end
end
assert(hover and hover:find('函数 `owned_9001`', 1, true), vim.inspect(hover))
assert(hover:find('function `owned_9002`', 1, true) and hover:find('function `owned_9003`', 1, true), hover)
assert(vim.deep_equal(responses, original), 'hover rewrote a response')
vim.api.nvim_win_close(hover_win, true)
vim.lsp.buf_request_all = request_all

local function progress(id, token, kind, title)
  vim.api.nvim_exec_autocmds('LspProgress', {
    pattern = kind, data = { client_id = id, params = { token = token, value = { kind = kind, title = title } } },
  })
end
progress(one.id, 1, 'begin', 'indexing')
progress(one.id, '1', 'begin', 'background')
progress(two.id, '1', 'begin', 'indexing')
progress(one.id, '1', 'end', 'background')
local clients = lsp.info(buf).clangd_clients
h.equal(#clients[1].progress_tokens, 1, 'end cleared another token')
h.equal(clients[1].progress.raw.token, 1, 'numeric token was conflated')
h.equal(clients[2].progress.title, 'indexing', 'unverified client progress translated')
h.equal(lsp.info(other_buf).clangd_clients[1].id, two.id, 'current project status ordering')

local status = vim.lsp.handlers['textDocument/clangd.fileStatus']
status(nil, { uri = vim.uri_from_bufnr(other_buf), state = 'parsing includes' }, { client_id = one.id })
h.equal(lsp.info(other_buf).background_clangd_clients[1].file_status, nil, 'foreign URI was cached')
local uri = vim.uri_from_bufnr(buf):gsub('%%%x%x', string.upper)
status(nil, { uri = uri, state = 'parsing includes' }, { client_id = one.id })
h.equal(lsp.info(buf).clangd_clients[1].file_status.uri, uri, 'wire URI was changed')
one.attached_buffers[buf] = nil
vim.api.nvim_exec_autocmds('LspDetach', { buffer = buf, data = { client_id = one.id } })
assert(vim.wait(1000, function() return lsp.info(buf).background_clangd_clients[1].progress == nil end))
h.equal(lsp.info(buf).background_clangd_clients[1].file_status, nil, 'detached file status survived')
vim.api.nvim_buf_delete(other_buf, { force = true })
packs.tool_reason, vim.lsp.get_clients = reason, get_clients
print('CLIENT_ISOLATION=PASS diagnostics push renderers hover token clients detach wipeout')
