local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local known = "Redefinition of 'x'"
local original_open_float = vim.diagnostic.open_float
local user_calls = 0
local user_format = function(diagnostic) user_calls = user_calls + 1; return diagnostic.message end
vim.diagnostic.config({ virtual_text = { format = user_format }, virtual_lines = { format = user_format }, float = { format = user_format } })
h.setup()
local diagnostic = {
  bufnr = 0, lnum = 0, end_lnum = 0, col = 4, end_col = 5,
  severity = vim.diagnostic.severity.ERROR, message = known, source = 'clangd', code = 'redefinition',
  tags = { 1 }, user_data = { lsp = { message = known, relatedInformation = { { message = 'Previous definition is here', location = { uri = 'file:///tmp/nvim-zh-fixture.cpp', range = { start = { line = 0, character = 4 }, ['end'] = { line = 0, character = 5 } } } } } } },
}
local snapshot = vim.deepcopy(diagnostic)
local vt = vim.diagnostic.config().virtual_text.format
local vl = vim.diagnostic.config().virtual_lines.format
equal(vt(diagnostic), "'x' 重复定义", 'virtual text diagnostic not translated')
equal(vl(diagnostic), "'x' 重复定义", 'virtual lines diagnostic not translated')
equal(user_calls, 2, 'user formatter was dropped or duplicated')
local coverage = require('nvim-zh.diagnostics').info()
equal(coverage.runtime_observed, 2, 'clangd runtime observed coverage missing')
equal(coverage.runtime_translated, 2, 'clangd runtime translated coverage missing')
local note = vim.deepcopy(diagnostic)
note.message = 'Previous definition is here'
equal(vt(note), '此前的定义在这里', 'second clangd corpus rule not translated')
check(vim.deep_equal(diagnostic, snapshot), 'formatter mutated original diagnostic')
local unknown = vim.deepcopy(diagnostic)
unknown.message = 'unknown clangd diagnostic'
equal(vt(unknown), unknown.message, 'unknown diagnostic did not fall back')
unknown.source, unknown.message = 'other-server', known
equal(vt(unknown), known, 'unknown server diagnostic did not fall back')
for _, message in ipairs({ '', '你好 🌏', 'line one\nline two', string.rep('long-文本-', 10000), '%s {name} %%' }) do
  unknown.source, unknown.message = 'clangd', message
  equal(vt(unknown), message, 'unsafe diagnostic fallback')
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'int x; int x;' })
local ns = vim.api.nvim_create_namespace('nvim-zh-diagnostic-display')
vim.diagnostic.set(ns, buf, { diagnostic })
vim.diagnostic.show(ns, buf)
local stored = vim.diagnostic.get(buf, { namespace = ns })[1]
equal(stored.message, known, 'stored diagnostic was translated')
check(vim.deep_equal(stored.user_data, diagnostic.user_data), 'stored user_data changed')
vim.diagnostic.setqflist({ open = false })
local qf = vim.fn.getqflist({ items = 1 }).items
check(vim.tbl_contains(vim.tbl_map(function(item) return item.text end, qf), known), 'quickfix diagnostic was translated')
vim.api.nvim_win_set_cursor(0, { 1, 4 })
local float_buf, float_win = vim.diagnostic.open_float({ namespace = ns, scope = 'line' })
check(float_buf and float_win, 'diagnostic float did not open')
local text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(text:find("'x' 重复定义", 1, true), 'float diagnostic not translated')
vim.api.nvim_win_close(float_win, true)

local before = user_calls
local previous_vt = vt
h.setup()
vt = vim.diagnostic.config().virtual_text.format
equal(vt, previous_vt, 'repeated setup replaced diagnostic formatter')
equal(vt(diagnostic), "'x' 重复定义", 'current diagnostic formatter after repeated setup')
equal(user_calls, before + 1, 'repeated setup stacked diagnostic formatter')
local throwing = function() error('user-format-error') end
local config_ok, config_err = pcall(vim.diagnostic.config, { virtual_text = { format = throwing } })
check(not config_ok and tostring(config_err):find('user-format-error', 1, true), 'user formatter error swallowed during display refresh')
dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
check(vim.diagnostic.config().virtual_text.format == throwing, 'reload reclaimed external diagnostic formatter')
vim.diagnostic.config({ virtual_text = false })
local ok, err = pcall(throwing, diagnostic)
check(not ok and tostring(err):find('user-format-error', 1, true), 'user formatter error changed')
h.setup({ enabled = false })
equal(vim.diagnostic.open_float, original_open_float, 'disabling diagnostics did not restore open_float')
require('nvim-zh.diagnostics').teardown()
print('DIAGNOSTIC_DISPLAY_SPEC=PASS stored=source quickfix=source float=translated metadata=preserved')
