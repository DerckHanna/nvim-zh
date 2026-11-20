local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
h.setup()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, '/tmp/nvim-zh-push-pull-fixture.cpp')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'int x;', 'int x;' })
vim.fn.bufload(buf)
vim.api.nvim_set_current_buf(buf)
local uri = vim.uri_from_bufnr(buf)
local workspace_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(workspace_buf, '/tmp/nvim-zh-workspace-pull-fixture.cpp')
vim.api.nvim_buf_set_lines(workspace_buf, 0, -1, false, { 'int x;', 'int x;' })
local workspace_uri = vim.uri_from_bufnr(workspace_buf)
local original = {
  range = { start = { line = 1, character = 4 }, ['end'] = { line = 1, character = 5 } },
  severity = 1, code = 'redefinition', source = 'clang', message = "Redefinition of 'x'",
  relatedInformation = { { location = { uri = uri, range = { start = { line = 0, character = 4 }, ['end'] = { line = 0, character = 5 } } }, message = 'Previous definition is here' } },
}
local snapshot = vim.deepcopy(original)
local completion_item = { label = 'indexing', data = { project = 'fixture' } }
local completion_result = vim.tbl_extend('force', vim.deepcopy(completion_item), {
  documentation = { kind = 'markdown', value = 'Parameters:' },
  textEdit = { range = vim.deepcopy(original.range), newText = 'indexing' },
})
local completion_snapshot = vim.deepcopy(completion_result)
local old_get = vim.lsp.get_client_by_id
vim.lsp.get_client_by_id = function(id)
  -- 0.11 derives the pull namespace from server_capabilities; newer versions use identifier.
  return { id = id, name = 'clangd', server_capabilities = { diagnosticProvider = { identifier = 'fixture' } } }
end
vim.lsp.diagnostic.on_publish_diagnostics(nil, { uri = uri, diagnostics = { original } }, { client_id = 91 })
local push_ns = vim.lsp.diagnostic.get_namespace(91, false)
local push = vim.diagnostic.get(buf, { namespace = push_ns })[1]
equal(push.message, original.message, 'push diagnostic storage changed')
check(vim.deep_equal(push.user_data.lsp, snapshot), 'push protocol diagnostic changed')
vim.lsp.get_client_by_id = old_get

-- Use the documented in-process vim.lsp.start() lifecycle on every version.
-- Nightly requires the resulting capability state; older versions exercise the
-- same public initialize/attach/request path instead of private enable helpers.
local pull_client_id = vim.lsp.start({
  name = 'clangd', root_dir = '/tmp',
  cmd = function(dispatchers)
    local closing, request_id = false, 0
    return {
      request = function(method, params, callback)
        if method == 'initialize' then
          callback(nil, { capabilities = {
            textDocumentSync = { openClose = true, change = 1 },
            diagnosticProvider = { identifier = 'fixture', workspaceDiagnostics = true },
            completionProvider = { resolveProvider = true },
          } })
        elseif method == 'textDocument/diagnostic' then
          callback(nil, { kind = 'full', resultId = 'fixed-result', items = { original } })
        elseif method == 'workspace/diagnostic' then
          equal(params.identifier, 'fixture', 'workspace pull identifier')
          callback(nil, { items = {
            { uri = workspace_uri, version = vim.NIL, kind = 'full', resultId = 'workspace-result', items = { original } },
          } })
        elseif method == 'completionItem/resolve' then
          check(vim.deep_equal(params, completion_item), 'completion resolve request changed')
          callback(nil, completion_result)
        elseif method == 'shutdown' then
          callback(nil, nil)
        end
        request_id = request_id + 1
        return true, request_id
      end,
      notify = function(method)
        if method == 'exit' then dispatchers.on_exit(0, 15) end
      end,
      is_closing = function() return closing end,
      terminate = function() closing = true end,
    }
  end,
}, { bufnr = buf })
check(pull_client_id ~= nil, 'in-process client did not start')
local pull_client = vim.lsp.get_client_by_id(pull_client_id)
check(vim.wait(2000, function()
  return pull_client.initialized and pull_client.attached_buffers[buf] ~= nil
end, 10), 'in-process client did not attach')
check(pull_client:request('textDocument/diagnostic', {
  textDocument = { uri = uri }, identifier = 'fixture',
}, nil, buf), 'pull request failed')
local pull_ns = vim.lsp.diagnostic.get_namespace(pull_client_id, true, 'fixture')
local pull
check(vim.wait(2000, function()
  pull = vim.diagnostic.get(buf, { namespace = pull_ns })[1]
  return pull ~= nil
end, 10), 'pull diagnostic was not stored')
equal(pull.message, original.message, 'pull diagnostic storage changed')
check(vim.deep_equal(pull.user_data.lsp, snapshot), 'pull protocol diagnostic changed')
if vim.lsp.buf.workspace_diagnostics then
  vim.lsp.buf.workspace_diagnostics({ client_id = pull_client_id })
  local workspace
  check(vim.wait(2000, function()
    workspace = vim.diagnostic.get(workspace_buf, { namespace = pull_ns })[1]
    return workspace ~= nil
  end, 10), 'workspace pull diagnostic was not stored')
  equal(workspace.message, original.message, 'workspace pull diagnostic storage changed')
  check(vim.deep_equal(workspace.user_data.lsp, snapshot), 'workspace pull protocol diagnostic changed')
  print('WORKSPACE_PULL_SPEC=PASS full_report protocol_metadata=identical')
end
local resolved
check(pull_client:supports_method('completionItem/resolve'), 'client lost the advertised resolve capability')
check(pull_client:request('completionItem/resolve', vim.deepcopy(completion_item), function(err, reply)
  check(err == nil, vim.inspect(err))
  resolved = reply
end, buf), 'completion resolve request failed')
check(vim.wait(2000, function() return resolved ~= nil end, 10), 'completion resolve callback was not invoked')
check(vim.deep_equal(resolved, completion_snapshot), 'completion resolve result changed')
check(vim.deep_equal(completion_result, completion_snapshot), 'completion resolve response mutated')
print('COMPLETION_RESOLVE_SPEC=PASS documentation insertion range and data preserved')
check(vim.deep_equal(original, snapshot), 'input diagnostic mutated')
pull_client:stop()
check(vim.wait(1000, function() return pull_client:is_stopped() end, 10), 'in-process client did not stop')
print('PUSH_PULL_SPEC=PASS push=pull=source protocol_metadata=identical public_client_lifecycle=true')
