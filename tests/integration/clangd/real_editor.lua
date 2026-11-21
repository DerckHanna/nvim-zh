local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local root = assert(vim.env.NVIM_ZH_TEST_CLANGD_WORK)
local executable = assert(vim.env.NVIM_ZH_TEST_CLANGD)
local path = root .. '/editor.cpp'
vim.fn.writefile({
  'int sum(int x, int y) { return x + y; }',
  'int main() {',
  '  int unused = 0;',
  '  return sum(1, 2)',
  '}',
  'double sum(double x, double y) { return x + y; }',
  'int signature_example() { return sum(1, 2); }',
  'auto completion_example() { su; }',
}, path)
vim.fn.writefile({vim.json.encode({{
  directory = root, file = path, arguments = { 'clang++', '-Wall', '-Wextra', '-c', path },
}})}, root .. '/compile_commands.json')

local progress, raw_progress = {}, {}
local handle_progress = vim.lsp.handlers['$/progress']
vim.lsp.handlers['$/progress'] = function(err, params, ctx)
  progress[#progress + 1] = vim.deepcopy(params)
  return handle_progress(err, params, ctx)
end

local events = {}
vim.api.nvim_create_autocmd('LspProgress', { callback = function(event)
  events[#events + 1] = vim.deepcopy(event.data.params)
end })
local selected_title, selection_error
local select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  if opts.kind ~= 'codeaction' then return select(items, opts, on_choice) end
  for index, item in ipairs(items) do
    if item.action.title == "insert ';'" then
      selected_title = opts.format_item(item)
      on_choice(item, index)
      return
    end
  end
  selection_error = 'clangd did not offer the semicolon fix'
end

require('nvim-zh').setup({
  modules = { core = { enabled = false }, help = { enabled = false }, plugins = { auto = false } },
})
vim.cmd.edit(vim.fn.fnameescape(path))
local bufnr = vim.api.nvim_get_current_buf()
vim.bo.filetype = 'cpp'
local client_id = assert(vim.lsp.start({
  name = 'clangd',
  cmd = { executable, '--background-index', '--completion-style=bundled', '--enable-config=false', '--log=error' },
  root_dir = root,
  capabilities = { textDocument = { publishDiagnostics = { relatedInformation = true } } },
  init_options = { fallbackFlags = { '-Wall', '-Wextra' } },
  handlers = {
    ['$/progress'] = function(err, params, ctx)
      raw_progress[#raw_progress + 1] = vim.deepcopy(params)
      return vim.lsp.handlers['$/progress'](err, params, ctx)
    end,
  },
}))
local client = assert(vim.lsp.get_client_by_id(client_id))
local semicolon
check(vim.wait(10000, function()
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if diagnostic.code == 'expected_semi_after_stmt' then semicolon = diagnostic end
  end
  return semicolon ~= nil
end, 25), 'clangd did not publish the expected C++ error')

local float_buf, float_win = vim.diagnostic.open_float({ scope = 'buffer' })
check(float_buf and float_win, 'diagnostic float did not open')
local diagnostic_text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(diagnostic_text:find("return 语句后缺少 ';'（有可用修复）", 1, true), 'semicolon error not shown in Chinese')
equal(semicolon.user_data.lsp.message, "Expected ';' after return statement (fix available)", 'raw diagnostic changed')
vim.api.nvim_win_close(float_win, true)

vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.lsp.buf.hover()
local hover_win
check(vim.wait(5000, function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
      if text:find('函数 `sum`', 1, true) and text:find('int sum(int x, int y)', 1, true) then
        hover_win = win
        return true
      end
    end
  end
end, 25), 'clangd hover did not show a Chinese label and the original C++ signature')
vim.api.nvim_win_close(hover_win, true)

vim.api.nvim_win_set_cursor(0, { semicolon.lnum + 1, semicolon.col })
vim.lsp.buf.code_action({ context = { diagnostics = { semicolon.user_data.lsp }, only = { 'quickfix' } } })
check(vim.wait(5000, function()
  return selection_error or vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1] == '  return sum(1, 2);'
end, 25), 'the displayed clangd code action did not apply')
check(not selection_error, selection_error)
equal(selected_title, "插入 ';'", 'clangd code action title not shown in Chinese')

local unused
check(vim.wait(10000, function()
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if diagnostic.code == '-Wunused-variable' then unused = diagnostic end
  end
  return unused ~= nil
end, 25), 'clangd did not publish the unused-variable warning after fixing the syntax error')
equal(unused.severity, vim.diagnostic.severity.WARN, 'warning severity changed')
equal(unused.user_data.lsp.message, "Unused variable 'unused'", 'raw warning changed')
float_buf, float_win = vim.diagnostic.open_float({ scope = 'buffer' })
check(float_buf and float_win, 'warning float did not open')
diagnostic_text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(diagnostic_text:find("变量 'unused' 未使用", 1, true), 'unused-variable warning not shown in Chinese')
vim.api.nvim_win_close(float_win, true)

local function request(method)
  local reply = assert(client:request_sync(method, vim.lsp.util.make_position_params(0, client.offset_encoding), 5000, bufnr))
  assert(not reply.err and reply.result, vim.inspect(reply))
  return reply.result
end

local signature_line = vim.api.nvim_buf_get_lines(bufnr, 6, 7, false)[1]
vim.api.nvim_win_set_cursor(0, { 7, assert(signature_line:find('sum(', 1, true)) + 4 })
local signatures = request('textDocument/signatureHelp').signatures
check(#signatures >= 2, vim.inspect(signatures))
vim.lsp.buf.signature_help()
local function preview(label)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
      if text:find(label, 1, true) then return win, text end
    end
  end
end
check(vim.wait(5000, function() return preview('函数签名：clangd') ~= nil end, 25), 'signature title did not appear')
local signature_win, signature_text = preview('函数签名：clangd')
check(signature_text:find('sum', 1, true), signature_text)
vim.api.nvim_win_close(signature_win, true)

local completion_line = vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1]
vim.api.nvim_win_set_cursor(0, { 8, assert(completion_line:find('su;', 1, true)) + 1 })
local result = request('textDocument/completion')
local completion_items = vim.lsp.completion._lsp_to_complete_items(result.items or result, 'su', client_id)
local completion
for _, item in ipairs(completion_items) do
  if item.word == 'sum' then completion = item; break end
end
check(completion ~= nil, vim.inspect(completion_items))
local raw_item = completion.user_data.nvim.lsp.completion_item
check(raw_item.label:find('sum', 1, true), vim.inspect(raw_item))
equal(completion.word, 'sum', 'completion insert text changed')
equal(raw_item.detail, '[2 overloads]', 'clangd did not bundle the expected overloads')
equal(completion.menu, '[2 个重载]', 'completion menu was not translated')

local function raw_index(rows)
  return vim.iter(rows):any(function(item) return item.value and item.value.title == 'indexing' end)
end
check(vim.wait(10000, function() return raw_index(raw_progress) and raw_index(progress) and raw_index(events) end, 25),
  'real clangd index progress did not reach all raw consumers')
local queued = {}
for item in client.progress do queued[#queued + 1] = item end
check(raw_index(queued), 'client.progress lost the raw title')
local lsp_status = require('nvim-zh').status().lsp.clangd_clients[1]
equal(lsp_status.progress.title, '正在建立索引', 'panel progress title not projected')
local downstream
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.lsp.buf_request_all(bufnr, 'textDocument/hover', function(c)
  return vim.lsp.util.make_position_params(0, c.offset_encoding)
end, function(responses) downstream = responses[client_id].result end)
check(vim.wait(5000, function() return downstream ~= nil end, 25), 'generic hover callback timed out')
check(downstream.contents.value:find('function `sum`', 1, true), 'generic hover callback received a projected document')

local tool = require('nvim-zh.packs')
local server_info = client.server_info
client.server_info = vim.tbl_extend('force', server_info, { version = 'unknown test version' })
equal(tool.tool_reason('clangd', client, 'textDocument/hover'), 'unsupported_version', 'unknown version accepted')
float_buf, float_win = vim.diagnostic.open_float({ scope = 'buffer' })
diagnostic_text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(diagnostic_text:find("Unused variable 'unused'", 1, true), diagnostic_text)
vim.api.nvim_win_close(float_win, true)
client.server_info = server_info
equal(tool.tool_reason('clangd', client, 'textDocument/diagnostic'), 'unverified_interface', 'unverified pull accepted')

vim.cmd.edit(vim.fn.fnameescape(root .. '/redefinition.cpp'))
vim.bo.filetype = 'cpp'
assert(vim.lsp.buf_attach_client(0, client_id))
local note
check(vim.wait(10000, function()
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    local related = diagnostic.user_data.lsp.relatedInformation
    if related and related[1] and related[1].message == 'Previous definition is here' then
      note = related[1]
      return true
    end
  end
end, 25), 'no related definition from clangd')
float_buf, float_win = vim.diagnostic.open_float({ scope = 'buffer' })
diagnostic_text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(diagnostic_text:find('此前的定义在这里', 1, true), diagnostic_text)
equal(note.message, 'Previous definition is here', 'raw related information was changed')
vim.api.nvim_win_close(float_win, true)

-- Two independent clients can have the same name and different evidence.
local original_buf = vim.api.nvim_get_current_buf()
local other_root = root .. '/second project'
vim.fn.mkdir(other_root, 'p')
local other_file = other_root .. '/second.cpp'
vim.fn.writefile({ 'int main() { return unknown_in_second_project; }' }, other_file)
vim.cmd.edit(vim.fn.fnameescape(other_file))
local other_buf = vim.api.nvim_get_current_buf()
local other_id = assert(vim.lsp.start({
  name = 'clangd', root_dir = other_root, cmd = { executable, '--log=error' },
  on_init = function(peer)
    peer.server_info = vim.tbl_extend('force', peer.server_info, { version = 'unverified peer' })
  end,
}, { reuse_client = function() return false end }))
check(other_id ~= client_id, 'separate projects reused a single client')
check(vim.wait(10000, function() return #vim.diagnostic.get(other_buf) > 0 end, 25),
  'second project did not publish diagnostics')
local function clients()
  return require('nvim-zh').status().lsp.clangd_clients
end
local peers = clients()
equal(#peers, 1, 'panel included a client outside the current project')
equal(peers[1].id, other_id, 'panel selected the first project client')
equal(peers[1].reason, 'unsupported_version', 'unverified peer inherited another client’s evidence')
float_buf, float_win = vim.diagnostic.open_float({ scope = 'buffer' })
diagnostic_text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(diagnostic_text:find("Use of undeclared identifier 'unknown_in_second_project'", 1, true),
  'unverified peer displayed a projected diagnostic')
vim.api.nvim_win_close(float_win, true)
vim.lsp.get_client_by_id(other_id):stop()
vim.api.nvim_set_current_buf(original_buf)
peers = clients()
equal(#peers, 1, 'stopped peer remained in the active project snapshot')
equal(peers[1].id, client_id, 'switch back did not restore the verified project status')
equal(peers[1].reason, 'verified', 'project switch lost verified capabilities')

client:stop()
print('REAL_CLANGD_EDITOR=PASS error warning related_information hover quickfix completion signature progress unknown_version multi_project')
print('REAL_CLANGD_COMPLETION=' .. vim.json.encode({ menu = completion.menu, detail = raw_item.detail, info = completion.info }))
