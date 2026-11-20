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
}, path)

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
  cmd = { executable, '--background-index=false', '--enable-config=false', '--log=error' },
  root_dir = root,
  init_options = { fallbackFlags = { '-Wall', '-Wextra' } },
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
client:stop()
print('REAL_CLANGD_EDITOR=PASS error warning hover quickfix')
