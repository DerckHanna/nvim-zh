local function check(value, message)
  if not value then error(message, 2) end
end
check(vim.fn.exists(':NvimZh') == 2, 'NvimZh not defined')
check(vim.fn.exists(':NvimZhCheck') == 2, 'NvimZhCheck not defined')
for _, command in ipairs({ 'NvimZhInfo', 'NvimZhMissing', 'NvimZhReload', 'NvimZhUpdate', 'NvimZhRollback' }) do
  check(vim.fn.exists(':' .. command) == 0, command .. ' must not be defined')
end
require('nvim-zh').setup()
check(vim.wait(20000, function() return require('nvim-zh').status().runtime.status ~= 'syncing' end, 20),
  'setup did not settle')
local notifications = {}
vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end
local before_lang = vim.v.lang
local before_lc_all = vim.env.LC_ALL
local before_helplang = vim.o.helplang
vim.cmd('NvimZhCheck')
check(#notifications == 1 and notifications[1].msg:find('nvim-zh', 1, true) ~= nil, 'NvimZhCheck did not report')
vim.cmd('NvimZh')
check(#notifications == 2 and notifications[2].msg:find('UI', 1, true) ~= nil, 'headless NvimZh did not report no UI')
check(vim.v.lang == before_lang and vim.env.LC_ALL == before_lc_all, 'check changed locale')
check(vim.o.helplang == before_helplang, 'check changed helplang')
print('COMMANDS_SPEC=PASS public_commands_only synchronous_check readonly')
