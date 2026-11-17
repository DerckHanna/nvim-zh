local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal
local original_keymap_set = vim.keymap.set
local maps = {}
local keymap_spy = function(mode, lhs, rhs, opts)
  table.insert(maps, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
  return 'map-return'
end
vim.keymap.set = keymap_spy
local tree = {}
local configured
tree.setup = function(opts) configured = opts; return 'setup-return' end
package.loaded['nvim-tree'] = tree
local original_setup = tree.setup
local overrides = h.overrides()
overrides['nvim-tree'] = { mapping = { Open = '打开', Help = '帮助' } }
h.setup({ auto = true, disabled = {} }, overrides)
local user_calls = {}
local rhs = function() return 'rhs-result' end
local user_on_attach = function(bufnr)
  table.insert(user_calls, bufnr)
  vim.keymap.set('n', 'o', rhs, { buffer = bufnr, desc = 'Open' })
  vim.keymap.set('n', '?', rhs, { buffer = bufnr, desc = 'Unknown mapping' })
end
local opts = { on_attach = user_on_attach, unrelated = { keep = true } }
equal(tree.setup(opts), 'setup-return', 'nvim-tree setup return changed')
check(configured.on_attach ~= user_on_attach, 'nvim-tree on_attach was not chained')
equal(opts.on_attach, user_on_attach, 'nvim-tree setup mutated user opts')
configured.on_attach(42)
equal(#user_calls, 1, 'user on_attach call count changed')
equal(user_calls[1], 42, 'user on_attach bufnr changed')
equal(vim.keymap.set, keymap_spy, 'keymap.set was not restored after on_attach')
equal(maps[1].opts.desc, '打开', 'nvim-tree mapping desc not translated')
equal(maps[1].lhs, 'o', 'nvim-tree lhs changed')
check(maps[1].rhs == rhs, 'nvim-tree rhs identity changed')
equal(maps[1].opts.buffer, 42, 'nvim-tree buffer changed')
equal(maps[2].opts.desc, 'Unknown mapping', 'unknown nvim-tree mapping changed')

configured.on_attach(43)
equal(#user_calls, 2, 'reused on_attach changed call count')
local failing = function() error('user-on-attach-error') end
tree.setup({ on_attach = failing })
local ok, err = pcall(configured.on_attach, 1)
check(not ok and tostring(err):find('user-on-attach-error', 1, true), 'user on_attach error swallowed')
equal(vim.keymap.set, keymap_spy, 'keymap.set leaked after on_attach error')
h.setup({ auto = true, disabled = { 'nvim-tree' } })
equal(tree.setup, original_setup, 'nvim-tree disable did not restore setup')
h.setup()
local external = function() return 'external-setup' end
tree.setup = external
require('nvim-zh').reload()
equal(tree.setup, external, 'reload reclaimed external nvim-tree setup')
require('nvim-zh.plugins').teardown()
equal(tree.setup, external, 'teardown reclaimed external nvim-tree setup')
vim.keymap.set = original_keymap_set
print('NVIM_TREE_ADAPTER_SPEC=PASS seam=setup.on_attach mapping=unchanged errors=propagated')
