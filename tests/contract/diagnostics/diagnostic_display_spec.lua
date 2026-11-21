local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local known = "Redefinition of 'x'"
local original_open_float = vim.diagnostic.open_float
local original_setqflist = vim.diagnostic.setqflist
local user_calls = 0
local user_format = function(diagnostic) user_calls = user_calls + 1; return diagnostic.message end
vim.diagnostic.config({ virtual_text = { format = user_format }, virtual_lines = { format = user_format }, float = { format = user_format } })
h.setup()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local ns = h.client(buf)
local diagnostic = {
  bufnr = buf, namespace = ns, lnum = 0, end_lnum = 0, col = 4, end_col = 5,
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

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'int x; int x;' })
vim.diagnostic.set(ns, buf, { diagnostic })
vim.diagnostic.show(ns, buf)
local stored = vim.diagnostic.get(buf, { namespace = ns })[1]
equal(stored.message, known, 'stored diagnostic was translated')
check(vim.deep_equal(stored.user_data, diagnostic.user_data), 'stored user_data changed')
local win = vim.api.nvim_get_current_win()
local list_calls = 0
local function list_format(row)
  list_calls = list_calls + 1
  if row.code == 'filtered' then return nil end
  return row.message
end
local filtered = vim.tbl_extend('force', diagnostic, { col = 1, code = 'filtered' })
vim.diagnostic.set(ns, buf, { filtered, diagnostic })
original_setqflist({ open = false, format = list_format })
local raw = vim.fn.getqflist()
vim.diagnostic.setqflist({ open = false, format = list_format })
equal(list_calls, 4, 'list formatter was dropped or duplicated')
check(vim.deep_equal(raw, vim.fn.getqflist()), 'quickfix raw entries changed')
equal(require('nvim-zh').raw().raw_text, known, 'raw command returned the translated message')
vim.cmd.copen()
local list_text = "'x' 重复定义"
check(vim.api.nvim_get_current_line():find(list_text, 1, true), 'quickfix diagnostic did not render')
vim.cmd.cc()
equal(vim.api.nvim_get_current_buf(), buf, 'quickfix jump changed buffer')
equal(vim.api.nvim_win_get_cursor(0)[2], 4, 'quickfix jump changed column')
vim.cmd.cclose()
vim.api.nvim_set_current_win(win)
vim.diagnostic.setloclist({ winnr = win, open = true, format = list_format })
equal(vim.fn.getloclist(win)[1].text, known, 'location list raw text changed')
check(vim.api.nvim_get_current_line():find(list_text, 1, true), 'location list diagnostic did not render')
vim.cmd.lclose()
vim.api.nvim_set_current_win(win)
local error_ok, error_message = pcall(vim.diagnostic.setqflist, { format = function() error('list-format-error') end })
check(not error_ok and tostring(error_message):find('list-format-error', 1, true), 'list formatter exception changed')
vim.diagnostic.set(ns, buf, { diagnostic, diagnostic })
vim.diagnostic.setqflist({ open = true })
check(vim.api.nvim_get_current_line():find(known, 1, true), 'ambiguous diagnostic list entries were projected')
vim.cmd.cclose()
local external_list = function() return { 'external' } end
vim.fn.setqflist({}, 'a', { quickfixtextfunc = external_list })
vim.diagnostic.set(ns, buf, { diagnostic })
vim.diagnostic.setqflist({ open = true })
check(rawequal(vim.fn.getqflist({ quickfixtextfunc = 1 }).quickfixtextfunc, external_list), 'external list formatter lost')
equal(vim.api.nvim_get_current_line(), 'external', 'external list formatter display changed')
vim.cmd.cclose()
vim.api.nvim_win_set_cursor(0, { 1, 4 })
local float_buf, float_win = vim.diagnostic.open_float({ namespace = ns, scope = 'line' })
check(float_buf and float_win, 'diagnostic float did not open')
local text = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n')
check(text:find("'x' 重复定义", 1, true), 'float diagnostic not translated')
if vim.fn.has('nvim-0.12') == 1 then
  check(text:find('nvim-zh-fixture.cpp:1:5: 此前的定义在这里', 1, true), 'float related information not translated')
  check(vim.deep_equal(vim.diagnostic.get(buf, { namespace = ns })[1].user_data, diagnostic.user_data),
    'float mutated stored related information')
end
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
equal(vim.diagnostic.setqflist, original_setqflist, 'disabling diagnostics did not restore setqflist')
require('nvim-zh.diagnostics').teardown()
print('DIAGNOSTIC_DISPLAY_SPEC=PASS stored=source quickfix=version_dependent float=translated metadata=preserved')
