local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then error(message .. ': ' .. tostring(actual), 2) end
end
check(vim.fn.exists(':NvimZhMissing') == 2, 'NvimZhMissing not defined')
check(vim.fn.exists(':NvimZhReload') == 2, 'NvimZhReload not defined')
local generation = 1
local domain = 'command-fixture'
require('nvim-zh').register_catalog(domain, function()
  return { schema = 1, domain = domain, locale = 'zh_CN', entries = {
    { context = '', msgid = 'Save', msgstr = generation == 1 and '保存' or '存盘' },
  } }
end)
require('nvim-zh').setup()
equal(require('nvim-zh').translate({ domain = domain, msgid = 'Save' }), '保存', 'initial catalog')
require('nvim-zh').translate({ domain = domain, msgid = 'Unknown command message' })
local notifications = {}
vim.notify = function(message) table.insert(notifications, message) end
vim.cmd('NvimZhMissing')
check(#notifications == 1, 'NvimZhMissing did not report')
check(notifications[1]:find('Unknown command message', 1, true), 'missing message absent from report')
check(notifications[1]:find('非全 Neovim 覆盖率', 1, true), 'runtime scope disclaimer absent')
check(notifications[1]:find('静态目录', 1, true), 'static catalog coverage absent')
generation = 2
vim.cmd('NvimZhReload')
equal(require('nvim-zh').translate({ domain = domain, msgid = 'Save' }), '存盘', 'reload did not refresh catalog')
check(#notifications == 2 and notifications[2]:find('目录', 1, true), 'NvimZhReload did not report catalog-only reload')
print('COMMANDS_PHASE2_SPEC=PASS')
