local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal
local notifications = {}
vim.notify = function(message) table.insert(notifications, message) end
require('nvim-zh').setup({ modules = { ui = { notify = false, prompts = false, echo = false } } })
equal(require('nvim-zh').translate({ domain = 'which-key', context = 'desc', msgid = 'Save File' }), '保存文件', 'built-in which-key PO')
equal(require('nvim-zh').translate({ domain = 'telescope', context = 'title', msgid = 'Find Files' }), '查找文件', 'built-in Telescope PO')
equal(require('nvim-zh').translate({ domain = 'nvim-tree', context = 'mapping', msgid = 'Open' }), '打开', 'built-in nvim-tree PO')
local info = require('nvim-zh').info()
check(info.config.modules.plugins.auto == true, 'plugins.auto default')
check(info.plugins['which-key'].reason == 'not_loaded' and info.plugins.telescope.reason == 'not_loaded', 'absent plugin status')

local manifest = vim.json.decode(table.concat(vim.fn.readfile(vim.env.NVIM_ZH_ROOT .. '/manifests/upstreams.json'), '\n'))
check(manifest.upstreams['which-key'].commit == info.plugins['which-key'].supported_commit, 'which-key manifest/version mismatch')
check(manifest.upstreams.telescope.commit == info.plugins.telescope.supported_commit, 'Telescope manifest/version mismatch')
check(manifest.upstreams['lazy.nvim'].adapter.status == 'implemented', 'lazy.nvim shared public capability missing')
check(manifest.upstreams['nvim-tree'].adapter.status == 'implemented', 'nvim-tree public capability missing')
check(manifest.upstreams['nvim-cmp'].adapter.status == 'inventory_only', 'nvim-cmp capability inventory missing')

require('nvim-zh').show_info()
local rendered = notifications[#notifications]
check(rendered:find('阶段 8', 1, true), 'Info phase not updated')
check(rendered:find('which-key', 1, true) and rendered:find('telescope', 1, true), 'Info omits plugin adapters')
vim.cmd('NvimZhReload')
rendered = notifications[#notifications]
check(rendered:find('目录', 1, true) and rendered:find('插件', 1, true), 'Reload omits plugin adapters')
print('PLUGIN_INTEGRATION_SPEC=PASS manifests=6 built_in_domains=which-key,telescope,nvim-tree')
