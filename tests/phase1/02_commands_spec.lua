local function check(value, message)
  if not value then error(message, 2) end
end
check(vim.fn.exists(':NvimZhInfo') == 2, 'NvimZhInfo not defined')
check(vim.fn.exists(':NvimZhCheck') == 2, 'NvimZhCheck not defined')
require('nvim-zh').setup()
local notifications = {}
vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end
local before_lang = vim.v.lang
local before_lc_all = vim.env.LC_ALL
local before_helplang = vim.o.helplang
vim.cmd('NvimZhInfo')
check(#notifications == 1 and notifications[1].msg:find('nvim-zh', 1, true) ~= nil, 'NvimZhInfo output missing')
vim.cmd('NvimZhCheck')
check(#notifications == 2, 'NvimZhCheck did not report')
check(vim.v.lang == before_lang and vim.env.LC_ALL == before_lc_all, 'check changed locale')
check(vim.o.helplang == before_helplang, 'check changed helplang')
print('COMMANDS_SPEC=PASS')
