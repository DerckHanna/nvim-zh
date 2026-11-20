-- Invoke real errors in the temporary Neovim prefix supplied by test_messages.py.
local function expect_error(label, fragment, fn)
  vim.v.errmsg = ''
  local ok, why = pcall(fn)
  assert(not ok and (tostring(why) .. vim.v.errmsg):find(fragment, 1, true),
    vim.inspect({ label = label, error = why, errmsg = vim.v.errmsg }))
end

expect_error('mixed Lua table', 'E5100: 无法转换给定的 Lua 表', function()
  vim.fn.string({ [1] = 'number', string = 'key' })
end)
expect_error('Lua thread', 'E5101: 无法转换给定的 Lua 类型', function()
  vim.fn.string(coroutine.create(function() end))
end)
expect_error('print converter', 'E5114: 转换 print', function()
  print(setmetatable({}, { __tostring = function() error('print marker') end }))
end)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line 1', 'line 2', 'aaabbb\235\128' })
vim.opt.endofline = false
vim.opt.fixendofline = false
expect_error('encoding conversion', 'E513: 写入错误，第 3 行转换失败', function()
  vim.cmd('write ++enc=latin1 ' .. vim.fn.fnameescape(vim.fn.tempname()))
end)

vim.cmd('nnoremap <F8> <Cmd>echo "one"<Cmd>echo "two"<CR>')
vim.api.nvim_feedkeys(vim.keycode('<F8>'), 'x', false)
assert(vim.v.errmsg:find('E1136: <Cmd> 映射', 1, true), vim.v.errmsg)
vim.schedule(function() error('schedule marker') end)
assert(vim.wait(1000, function() return vim.v.errmsg:find('vim.schedule 回调', 1, true) end))

vim.api.nvim_create_user_command('NativeDrift', function() error('command marker') end, {})
expect_error('user command', 'Lua :command 回调', vim.cmd.NativeDrift)
local listener = vim.on_key(function() error('on_key marker') end)
expect_error('on_key', 'vim.on_key() 回调', function() vim.cmd.normal('h') end)
vim.on_key(nil, listener)

vim._expand_pat = function() error('expand marker') end
expect_error('command completion', 'vim._expand_pat：', function()
  vim.fn.getcompletion('lua vim.foo', 'cmdline')
end)

local group = vim.api.nvim_create_augroup('NativeDrift', { clear = true })
vim.api.nvim_create_autocmd('User', { group = group, pattern = 'Drift', callback = function() error('autocmd marker') end })
vim.api.nvim_exec_autocmds('User', { pattern = 'Drift' })

vim.o.shada = "'100,%"
local shada = vim.fn.tempname()
local file = assert(io.open(shada, 'wb'))
-- ShaDa buffer-list entry with a scalar where the buffer dictionary belongs.
file:write(string.char(9, 0, 2, 0x91, 0x01))
file:close()
expect_error('malformed ShaDa buffer list', 'E575: 读取 ShaDa 文件时出错：位置 0', function()
  vim.cmd('rshada! ' .. vim.fn.fnameescape(shada))
end)
print('NATIVE_DRIFT_RUNTIME=PASS')
