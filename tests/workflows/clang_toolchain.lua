vim.opt.loadplugins = false
vim.opt.rtp:prepend(vim.env.NVIM_ZH_ROOT)
vim.cmd('runtime plugin/nvim-zh.lua')
vim.o.shortmess = 'I'
vim.o.winborder = 'single'
vim.o.shell = '/bin/sh'
vim.o.shellpipe = '>%s 2>&1'
vim.o.makeef = vim.uv.cwd() .. '/build.out'
vim.o.completeopt = 'menu,menuone,noselect'
vim.keymap.set('i', '<F5>', function() vim.lsp.completion.get() end)
local zh = require('nvim-zh')
local enabled = vim.env.NVIM_ZH_LANGUAGE == 'on'
T = { raw = {}, wire = {}, displayed = {}, builds = {} }
local file_method = 'textDocument/clangd.fileStatus'
vim.lsp.handlers[file_method] = function(_, params) T.raw_file = vim.deepcopy(params) end
vim.api.nvim_create_autocmd('LspProgress', { callback = function(ev)
  local value = ev.data.params.value
  if value.kind == 'begin' then T.raw_progress = vim.deepcopy(ev.data.params) end
end })
vim.api.nvim_create_autocmd('QuickFixCmdPost', { pattern = { 'make', 'lmake' }, callback = function(ev)
  local fd = assert(vim.uv.fs_open(vim.o.makeef, 'r', 0))
  local size = assert(vim.uv.fs_fstat(fd)).size
  local bytes = assert(vim.uv.fs_read(fd, size, 0))
  vim.uv.fs_close(fd)
  local query = { items = 1, title = 1, idx = 0, context = 1 }
  local list = ev.match == 'lmake' and vim.fn.getloclist(0, query) or vim.fn.getqflist(query)
  T.builds[#T.builds + 1] = { bytes = bytes, exit = vim.v.shell_error, list = list }
end })
zh.setup({
  modules = {
    core = { enabled = false }, help = { enabled = enabled },
    compiler = { enabled = enabled }, diagnostics = { enabled = enabled },
    lsp = { hints = enabled, messages = enabled, progress = enabled }, plugins = { auto = false },
  },
})
assert(zh.status().runtime.status == 'ok', vim.inspect(zh.status().runtime))
for _, tool in ipairs({ 'clang', 'clangd', 'clang-tidy' }) do
  local path = vim.env.NVIM_ZH_TEST_TOOLCHAIN_ASSETS .. '/' .. tool .. '-zh_CN.json'
  local asset = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  vim.cmd.NvimZhPacks({ args = { 'import', path }, mods = { silent = true } })
  assert(zh.status().packs[tool].active == asset.manifest.version)
end
vim.api.nvim_create_autocmd('QuickFixCmdPost', { pattern = { 'make', 'lmake' }, callback = function(ev)
  local query = { items = 1, title = 1, idx = 0, context = 1 }
  local list = ev.match == 'lmake' and vim.fn.getloclist(0, query) or vim.fn.getqflist(query)
  local first = T.builds[#T.builds]
  assert(vim.deep_equal(first.list, list) and first.exit == vim.v.shell_error, 'quickfix changed during display setup')
end })

function T.start()
  local rpc_start = vim.lsp.rpc.start
  local client_id = assert(vim.lsp.start({
    name = 'clangd',
    cmd = function(dispatchers)
      local server_request = dispatchers.server_request
      dispatchers.server_request = function(method, params)
        local raw_params = vim.deepcopy(params)
        local result, err = server_request(method, params)
        T.wire[#T.wire + 1] = { method = method, server_request = raw_params,
          result = vim.deepcopy(result), error = vim.deepcopy(err) }
        return result, err
      end
      local notification = dispatchers.notification
      dispatchers.notification = function(method, params)
        T.wire[#T.wire + 1] = { method = method, params = vim.deepcopy(params) }
        return notification(method, params)
      end
      local rpc = rpc_start({ 'clangd', '--background-index', '--completion-style=bundled', '--log=error',
        '--hidden-features' }, dispatchers)
      local request = rpc.request
      rpc.request = function(method, params, callback, ...)
        return request(method, params, function(err, result)
          T.wire[#T.wire + 1] = { method = method, request = vim.deepcopy(params),
            error = vim.deepcopy(err), result = vim.deepcopy(result) }
          return callback(err, result)
        end, ...)
      end
      return rpc
    end,
    root_dir = vim.uv.cwd(),
    capabilities = { window = { workDoneProgress = true },
      textDocument = { publishDiagnostics = { relatedInformation = true } } },
    init_options = { clangdFileStatus = true },
  }))
  T.client = assert(vim.lsp.get_client_by_id(client_id))
  vim.lsp.completion.enable(true, client_id, 0, { autotrigger = false })
end

function T.diagnostic(code, key, line)
  return vim.wait(10000, function()
    for _, row in ipairs(vim.diagnostic.get(0, { lnum = line })) do
      if row.code == code then
        T.raw[key] = vim.deepcopy(row.user_data.lsp)
        return true
      end
    end
  end, 25)
end

function T.pull()
  local uri = vim.uri_from_bufnr(0)
  for method, params in pairs({
    ['textDocument/diagnostic'] = { textDocument = { uri = uri } },
    ['workspace/diagnostic'] = { previousResultIds = {} },
    ['completionItem/resolve'] = { label = 'sum' },
  }) do
    local reply = assert(T.client:request_sync(method, params, 5000, 0))
    assert(reply.err and reply.err.code == -32601, vim.inspect(reply))
    T.raw[method] = reply
  end
end

function T.notify_tweak()
  local position = { line = 1, character = 6 }
  local params = { textDocument = { uri = vim.uri_from_bufnr(0) },
    range = { start = position, ['end'] = position }, context = { diagnostics = {}, only = { 'info' } } }
  local reply = assert(T.client:request_sync('textDocument/codeAction', params, 5000, 0))
  local action = vim.iter(reply.result or {}):find(function(item)
    return item.title and item.title:match('^Dump .* AST$')
  end)
  assert(action and action.command, vim.inspect(reply))
  local command = assert(T.client:request_sync('workspace/executeCommand', action.command, 5000, 0))
  assert(not command.err, vim.inspect(command))
end

function T.apply_edit()
  local diagnostic = T.raw.apply_edit
  local params = { textDocument = { uri = vim.uri_from_bufnr(0) }, range = diagnostic.range,
    context = { diagnostics = { diagnostic }, only = { 'quickfix' } } }
  local reply = assert(T.client:request_sync('textDocument/codeAction', params, 5000, 0))
  local action = vim.iter(reply.result or {}):find(function(item) return item.edit ~= nil end)
  assert(action and action.edit, vim.inspect(reply))
  local response = assert(T.client:request_sync('workspace/executeCommand', {
    command = 'clangd.applyFix', arguments = { action.edit },
  }, 5000, 0))
  assert(response.result == 'Fix applied.', vim.inspect(response))
  T.raw.apply_edit_result = response.result
end

function T.symbol()
  local reply = assert(T.client:request_sync('workspace/symbol', { query = 'indexing' }, 5000, 0))
  assert(not reply.err, vim.inspect(reply))
  local symbol = vim.iter(reply.result or {}):find(function(item) return item.name == 'indexing' end)
  if symbol then T.raw.symbol = vim.deepcopy(symbol) end
  return symbol ~= nil
end

function T.analyzer_push()
  local filename = vim.api.nvim_buf_get_name(0)
  return vim.wait(10000, function()
    for _, row in ipairs(T.wire) do
      if row.method == 'textDocument/publishDiagnostics' and vim.uri_to_fname(row.params.uri) == filename then
        assert(#row.params.diagnostics == 1 and row.params.diagnostics[1].code == 'modernize-use-nullptr',
          vim.inspect(row.params))
        T.raw.analyzer_push = vim.deepcopy(row.params)
        return true
      end
    end
  end, 25)
end

function T.display_status()
  local client = zh.status().lsp.clangd_clients[1]
  T.displayed.progress = enabled and client.progress or T.raw_progress and T.raw_progress.value
  T.displayed.file = enabled and client.file_status or T.raw_file
  return T.displayed.progress ~= nil and T.displayed.file ~= nil
end

function T.compiler_ready()
  return not enabled or vim.wait(5000, function()
    local state = zh.status().compiler.last
    return state ~= nil and state.reason ~= 'probing'
  end, 10)
end

function T.snapshot()
  for method, params in pairs({ ['$/progress'] = T.raw_progress, [file_method] = T.raw_file }) do
    assert(vim.iter(T.wire):any(function(row) return row.method == method and vim.deep_equal(row.params, params) end),
      'downstream event or handler diverged from wire: ' .. method)
  end
  local output = { raw = T.raw, wire = T.wire, displayed = T.displayed, builds = T.builds,
    compiler = zh.status().compiler, lsp = zh.status().lsp, capabilities = T.client.server_capabilities,
    language = vim.env.NVIM_ZH_LANGUAGE }
  vim.fn.writefile({ vim.json.encode(output) }, vim.env.NVIM_ZH_TOOLCHAIN_RESULT)
end

vim.schedule(function() print('TOOLCHAIN_READY') end)
