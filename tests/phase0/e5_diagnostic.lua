local function check(value, message)
  if not value then error(message, 2) end
end
local known = "use of undeclared identifier 'foo'"
local unknown = 'a previously unseen server diagnostic'
local function format(diagnostic)
  if diagnostic.message == known then return "使用了未声明的标识符 'foo'" end
  return diagnostic.message
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'foo;', 'unknown;' })
local ns = vim.api.nvim_create_namespace('nvim-zh-phase0-diagnostic')
local original_lsp = {
  range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 3 } },
  message = known,
  code = 'clang-diagnostic',
}
local original_copy = vim.deepcopy(original_lsp)
local diagnostics = {
  {
    lnum = 0, col = 0, end_lnum = 0, end_col = 3,
    severity = vim.diagnostic.severity.ERROR,
    message = known, source = 'clangd', code = 'clang-diagnostic',
    user_data = { lsp = original_lsp },
  },
  {
    lnum = 1, col = 0, end_lnum = 1, end_col = 7,
    severity = vim.diagnostic.severity.WARN,
    message = unknown, source = 'clangd',
  },
}
vim.diagnostic.config({
  virtual_text = { format = format },
  virtual_lines = { format = format },
  float = { format = format },
}, ns)
vim.diagnostic.set(ns, buf, diagnostics)
vim.diagnostic.show(ns, buf)
check(vim.deep_equal(original_lsp, original_copy), 'input LSP diagnostic was mutated')
local stored = vim.diagnostic.get(buf, { namespace = ns })
check(#stored == 2, 'diagnostic count changed')
check(stored[1].message == known and stored[2].message == unknown, 'stored diagnostic message changed')
check(stored[1].user_data.lsp.message == known and stored[1].code == 'clang-diagnostic', 'diagnostic metadata changed')

local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
local rendered = vim.inspect(marks)
check(rendered:find("使用了未声明的标识符 'foo'", 1, true) ~= nil, 'virtual display did not use translation')
check(rendered:find(unknown, 1, true) ~= nil, 'unknown diagnostic did not fall back to source')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
-- 0.12.6 open_float inherits global float config, not namespace float config.
-- A display adapter therefore injects format through open_float call options.
local plain_buf, plain_win = vim.diagnostic.open_float({ namespace = ns, scope = 'line', source = true })
check(plain_buf and plain_win, 'plain diagnostic float did not open')
local plain_text = table.concat(vim.api.nvim_buf_get_lines(plain_buf, 0, -1, false), '\n')
local namespace_float_inherited = plain_text:find("使用了未声明的标识符 'foo'", 1, true) ~= nil
vim.api.nvim_win_close(plain_win, true)
local float_buf, float_win = vim.diagnostic.open_float({ namespace = ns, scope = 'line', source = true, format = format })
check(float_buf and float_win, 'translated diagnostic float did not open')
local float_text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(float_text:find("使用了未声明的标识符 'foo'", 1, true) ~= nil, 'float call formatter did not use translation')
check(float_text:find('clangd', 1, true) ~= nil, 'diagnostic source was removed from float')
vim.api.nvim_win_close(float_win, true)
print(('E5_DIAGNOSTIC_STATUS=PASS stored=source virtual_text=translated virtual_lines=translated float=translated_via_call_opts namespace_float_config=%s fallback=source metadata=preserved'):format(namespace_float_inherited and 'inherited' or 'not_inherited'))
