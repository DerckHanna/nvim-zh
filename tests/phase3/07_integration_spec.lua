local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase3/helpers.lua')
local check, equal = h.check, h.equal

local notifications = {}
vim.notify = function(msg) table.insert(notifications, msg) return 'ok' end
local echo = vim.api.nvim_echo
require('nvim-zh').setup({ missing = { enabled = true, max_entries = 32 } })
equal(require('nvim-zh').translate({ domain = 'nvim-ui', msgid = 'Ready' }), '就绪', 'built-in UI PO catalog')
equal(require('nvim-zh').translate({ domain = 'nvim-zh', msgid = 'Missing translations' }), '缺失翻译', 'existing catalog regression')
local info = require('nvim-zh').info()
check(info.config.modules.ui.notify == true and info.config.modules.ui.prompts == true, 'default notify/prompts config')
check(info.config.modules.ui.echo == false and info.config.modules.ui.select_items == false, 'unsafe UI features enabled by default')
check(info.ui.notify.active and info.ui.input.active and info.ui.select.active, 'Info active adapter state missing')
check(not info.ui.echo.active and vim.api.nvim_echo == echo, 'Info/default echo state mismatch')

require('nvim-zh').show_info()
local rendered = notifications[#notifications]
check(rendered:find('阶段', 1, true), 'NvimZhInfo phase header missing')
check(rendered:find('UI', 1, true) and rendered:find('notify', 1, true), 'NvimZhInfo omits UI adapter status')

vim.cmd('NvimZhReload')
rendered = notifications[#notifications]
check(rendered:find('目录', 1, true) and rendered:find('适配器', 1, true), 'NvimZhReload omits adapter reload')
check(info.ui ~= nil, 'Info UI table missing')
print('UI_INTEGRATION_SPEC=PASS domains=nvim-zh,nvim-ui')
