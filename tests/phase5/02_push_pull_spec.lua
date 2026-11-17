local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase5/helpers.lua')
local check, equal = h.check, h.equal
h.setup()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, '/tmp/nvim-zh-push-pull-fixture.cpp')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'int x;', 'int x;' })
vim.fn.bufload(buf)
vim.api.nvim_set_current_buf(buf)
local uri = vim.uri_from_bufnr(buf)
local original = {
  range = { start = { line = 1, character = 4 }, ['end'] = { line = 1, character = 5 } },
  severity = 1, code = 'redefinition', source = 'clang', message = "Redefinition of 'x'",
  relatedInformation = { { location = { uri = uri, range = { start = { line = 0, character = 4 }, ['end'] = { line = 0, character = 5 } } }, message = 'Previous definition is here' } },
}
local snapshot = vim.deepcopy(original)
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
      request = function(method, _params, callback)
        if method == 'initialize' then
          callback(nil, { capabilities = {
            textDocumentSync = { openClose = true, change = 1 },
            diagnosticProvider = { identifier = 'fixture' },
          } })
        elseif method == 'textDocument/diagnostic' then
          callback(nil, { kind = 'full', resultId = 'fixed-result', items = { original } })
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
check(vim.deep_equal(original, snapshot), 'input diagnostic mutated')
pull_client:stop()
check(vim.wait(1000, function() return pull_client:is_stopped() end, 10), 'in-process client did not stop')
print('PUSH_PULL_SPEC=PASS push=pull=source protocol_metadata=identical public_client_lifecycle=true')
