local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal = h.check, h.equal

local notifications = {}
vim.notify = function(msg) table.insert(notifications, msg) return 'ok' end
local echo = vim.api.nvim_echo
require('nvim-zh').setup({ missing = { enabled = true, max_entries = 32 } })
equal(require('nvim-zh').translate({ domain = 'nvim-ui', msgid = 'No information available' }), '没有可用的信息', 'built-in UI PO catalog')
local info = require('nvim-zh').status()
check(info.config.modules.ui.notify == true and info.config.modules.ui.prompts == true, 'default notify/prompts config')
check(info.config.modules.ui.echo == false and info.config.modules.ui.select_items == false, 'unsafe UI features enabled by default')
check(info.ui.notify.active and info.ui.input.active and info.ui.select.active, 'Info active adapter state missing')
check(not info.ui.echo.active and vim.api.nvim_echo == echo, 'Info/default echo state mismatch')

dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
check(require('nvim-zh').status().ui.notify.active, 'refresh lost UI adapter')
check(require('nvim-zh').status().version.running_version ~= nil, 'running version missing')
print('UI_INTEGRATION_SPEC=PASS production_catalog status refresh')
