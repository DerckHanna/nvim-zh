local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local po = table.concat(vim.fn.readfile(vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/nvim-tree.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po:find(forbidden, 1, true), 'nvim-tree PO contains forbidden terminology: ' .. forbidden)
end
local zh = require('nvim-zh')
zh.register_catalog('nvim-tree', function()
  return { schema = 1, domain = 'nvim-tree', locale = 'zh_CN', entries = {
    { context = 'mapping', msgid = 'Open', msgstr = '打开' },
    { context = 'mapping', msgid = 'Help', msgstr = '帮助' },
    { context = 'notification', msgid = 'No bookmarks to delete.', msgstr = '没有可删除的书签。' },
  } }
end, { locale = 'zh_CN', source = 'pinned-test-catalog' })
local original_keymap_set = vim.keymap.set
local maps = {}
local keymap_spy = function(mode, lhs, rhs, opts)
  maps[#maps + 1] = { mode = mode, lhs = lhs, rhs = rhs, opts = opts }
  return 'map-return'
end
vim.keymap.set = keymap_spy

local overrides = h.overrides()
overrides['nvim-tree'] = {
  mapping = { Open = '打开', Help = '帮助' },
  notification = { ['No bookmarks to delete.'] = '没有可删除的书签。' },
}

local function info()
  return zh.status().plugins['nvim-tree']
end

local function source_registered()
  for _, source in ipairs(zh.status().ui.sources) do
    if source.title == 'NvimTree' then
      return source.domain == 'nvim-tree' and source.context == 'notification'
    end
  end
  return false
end

package.loaded['nvim-tree'] = nil
package.loaded['nvim-tree.keymap'] = nil
package.loaded['nvim-tree.config'] = nil
h.setup({ auto = true, disabled = {} }, overrides)
check(package.loaded['nvim-tree'] == nil, 'adapter forced nvim-tree to load')
check(package.loaded['nvim-tree.keymap'] == nil, 'adapter forced an unconfigured keymap to load')
equal(info().reason, 'not_loaded', 'unloaded reason')
check(source_registered(), 'notification source was not registered without loading nvim-tree')

local config = { g = nil }
package.loaded['nvim-tree.config'] = config
local rhs = function() return 'rhs-result' end
local function make_keymap()
  local keymap = { calls = 0 }
  keymap.on_attach_default = function(bufnr)
    keymap.calls = keymap.calls + 1
    vim.keymap.set('n', 'o', rhs, {
      desc = 'nvim-tree: Open', buffer = bufnr, noremap = true, silent = true, nowait = true,
    })
    vim.keymap.set('n', 'g?', rhs, { desc = 'nvim-tree: Help', buffer = bufnr })
    vim.keymap.set('n', 'u', rhs, { desc = 'Open', buffer = bufnr })
    return 'default-return', nil, 'tail'
  end
  return keymap
end

local keymap = make_keymap()
local original_default = keymap.on_attach_default
local keymap_loads = 0
package.preload['nvim-tree.keymap'] = function()
  keymap_loads = keymap_loads + 1
  return keymap
end

local configured
local throw_setup = false
local tree = {}
local original_setup = function(opts)
  if throw_setup then error('tree-setup-error') end
  configured = opts
  config.g = { on_attach = opts and opts.on_attach or 'default' }
  return 'setup-return', nil, 'tail'
end
tree.setup = original_setup
package.loaded['nvim-tree'] = tree

h.setup({ auto = true, disabled = {} }, overrides)
check(tree.setup ~= original_setup, 'tree setup lifecycle was not adapted')
equal(keymap_loads, 0, 'keymap loaded before tree setup')
equal(info().reason, 'waiting_for_setup', 'pre-setup reason')
check(info().setup_active and not info().active, 'pre-setup capability state is wrong')
local setup_wrapper = tree.setup
h.setup({ auto = true, disabled = {} }, overrides)
check(tree.setup == setup_wrapper, 'repeated setup stacked tree setup wrapper')
equal(keymap_loads, 0, 'repeated setup loaded keymap before config.g existed')

local setup_returns = h.pack(tree.setup({}))
equal(setup_returns.n, 3, 'tree setup return arity')
equal(setup_returns[1], 'setup-return', 'tree setup first return')
equal(setup_returns[3], 'tail', 'tree setup tail return')
equal(keymap_loads, 1, 'post-setup keymap load count')
check(package.loaded['nvim-tree.keymap'] == keymap, 'post-setup keymap module missing')
check(keymap.on_attach_default ~= original_default, 'default on_attach was not wrapped after setup')
check(info().active, 'default mapping capability not active after setup')
check(type(info().version_related) == 'string' and info().supported_commit
  == '69eb0c34ed3d836d5a0d92d913b77dd73b054f2f', 'pinned seam metadata missing')

equal(zh.translate({ domain = 'nvim-tree', context = 'mapping', msgid = 'Open' }), '打开',
  'mapping suffix missing from active catalog')
local default_returns = h.pack(keymap.on_attach_default(42))
equal(default_returns.n, 3, 'default on_attach return arity')
equal(default_returns[1], 'default-return', 'default on_attach first return')
equal(default_returns[3], 'tail', 'default on_attach tail return')
equal(keymap.calls, 1, 'default on_attach call count')
equal(maps[1].opts.desc, 'nvim-tree: 打开', 'ASCII prefix or Open translation changed')
equal(maps[2].opts.desc, 'nvim-tree: 帮助', 'ASCII prefix or Help translation changed')
equal(maps[3].opts.desc, 'Open', 'unprefixed description changed')
equal(maps[1].lhs, 'o', 'default lhs changed')
check(maps[1].rhs == rhs, 'default rhs identity changed')
equal(maps[1].opts.buffer, 42, 'default buffer changed')
check(maps[1].opts.noremap and maps[1].opts.silent and maps[1].opts.nowait, 'default mapping options changed')
equal(vim.keymap.set, keymap_spy, 'keymap.set leaked after default attach')

local user_calls = {}
local user_on_attach = function(bufnr)
  user_calls[#user_calls + 1] = bufnr
  vim.keymap.set('n', 'o', rhs, { buffer = bufnr, desc = 'Open' })
  vim.keymap.set('n', '?', rhs, { buffer = bufnr, desc = 'nvim-tree: Help' })
end
local user_opts = { on_attach = user_on_attach, unrelated = { keep = true } }
tree.setup(user_opts)
check(configured == user_opts, 'tree setup mutated or replaced user opts')
check(configured.on_attach == user_on_attach, 'user on_attach was chained')
maps = {}
user_on_attach(43)
equal(user_calls[1], 43, 'user on_attach bufnr changed')
equal(maps[1].opts.desc, 'Open', 'user description colliding with catalog was translated')
equal(maps[2].opts.desc, 'nvim-tree: Help', 'user prefixed description was translated')
equal(vim.keymap.set, keymap_spy, 'custom on_attach changed keymap.set ownership')

throw_setup = true
local ok, err = pcall(tree.setup, {})
throw_setup = false
check(not ok and tostring(err):find('tree-setup-error', 1, true), 'tree setup error was swallowed')

-- A whole new module table is a new generation; restore only our old wrapper.
local retained_old_default = keymap.on_attach_default
local next_keymap = make_keymap()
local next_original_default = next_keymap.on_attach_default
package.loaded['nvim-tree.keymap'] = next_keymap
zh.refresh()
equal(keymap.on_attach_default, original_default, 'old keymap generation was not restored')
check(next_keymap.on_attach_default ~= next_original_default, 'new keymap generation was not adapted')
maps = {}
next_keymap.on_attach_default(44)
equal(maps[1].opts.desc, 'nvim-tree: 打开', 'new keymap generation did not translate')
equal(maps[1].opts.buffer, 44, 'new keymap generation buffer changed')
maps = {}
retained_old_default(45)
equal(maps[1].opts.desc, 'nvim-tree: Open', 'stale retained wrapper still translated')
equal(maps[1].opts.buffer, 45, 'stale retained wrapper changed original buffer')

-- Replacing one function in a live module is an external override, not a generation.
local external_default = function() return 'external-default' end
next_keymap.on_attach_default = external_default
zh.refresh()
check(next_keymap.on_attach_default == external_default, 'refresh reclaimed external default on_attach')
equal(info().reason, 'external_override', 'external default override not reported')

local next_tree = {}
local next_original_setup = function(opts)
  configured = opts
  config.g = config.g or { on_attach = 'default' }
  return 'next-setup-return'
end
next_tree.setup = next_original_setup
package.loaded['nvim-tree'] = next_tree
zh.refresh()
equal(tree.setup, original_setup, 'old tree generation was not restored')
check(next_tree.setup ~= next_original_setup, 'new tree generation was not adapted')
check(next_keymap.on_attach_default == external_default, 'tree generation reclaimed external keymap')

local external_setup = function() return 'external-setup' end
next_tree.setup = external_setup
zh.refresh()
check(next_tree.setup == external_setup, 'refresh reclaimed external tree setup')
equal(info().setup_reason, 'external_override', 'external setup override not reported')

-- Disable/teardown must not erase same-module external ownership memories.
require('nvim-zh.plugins').teardown()
check(next_tree.setup == external_setup, 'teardown reclaimed external tree setup')
check(next_keymap.on_attach_default == external_default, 'teardown reclaimed external default on_attach')
h.setup({ auto = true, disabled = {} }, overrides)
check(next_tree.setup == external_setup, 're-attach after teardown reclaimed external tree setup')
check(next_keymap.on_attach_default == external_default, 're-attach after teardown reclaimed external default')
equal(info().setup_reason, 'external_override', 're-attach forgot external setup ownership')
equal(info().keymap_reason, 'external_override', 're-attach forgot external keymap ownership')

local final_keymap = make_keymap()
local final_original_default = final_keymap.on_attach_default
package.loaded['nvim-tree.keymap'] = final_keymap
zh.refresh()
check(final_keymap.on_attach_default ~= final_original_default, 'generation after external override not adapted')
check(next_keymap.on_attach_default == external_default, 'module transition removed external function')
require('nvim-zh.plugins').teardown()
equal(final_keymap.on_attach_default, final_original_default, 'teardown did not restore current keymap')
check(next_tree.setup == external_setup, 'teardown reclaimed external tree setup')
check(not source_registered(), 'teardown left notification source registered')
vim.keymap.set = original_keymap_set
print('NVIM_TREE_ADAPTER_SPEC=PASS lazy_safe_setup custom_desc=original generations external_override teardown')
