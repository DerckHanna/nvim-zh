local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal
local lazy_root = vim.env.NVIM_ZH_TEST_LAZY
local tree_root = vim.env.NVIM_ZH_TEST_NVIM_TREE
local cmp_root = vim.env.NVIM_ZH_TEST_NVIM_CMP
if not lazy_root or not tree_root or not cmp_root then
  print('ADDITIONAL_UPSTREAM_SMOKE_SPEC=SKIP set NVIM_ZH_TEST_LAZY/NVIM_ZH_TEST_NVIM_TREE/NVIM_ZH_TEST_NVIM_CMP')
  return
end
vim.opt.runtimepath:prepend(lazy_root)
vim.opt.runtimepath:prepend(tree_root)
vim.opt.runtimepath:prepend(cmp_root)
local lazy = require('lazy')
local tree = require('nvim-tree')
local cmp = require('cmp')
check(type(lazy.setup) == 'function' and type(tree.setup) == 'function' and type(cmp.setup) == 'table', 'real upstream public setup missing')
local original_tree_setup = tree.setup
h.setup()
check(tree.setup ~= original_tree_setup, 'real nvim-tree adapter not attached')
tree.setup({ on_attach = function(bufnr)
  vim.keymap.set('n', 'o', '<Nop>', { buffer = bufnr, desc = 'Open' })
end, log = { enable = false } })
local buf = vim.api.nvim_create_buf(false, true)
require('nvim-tree.keymap').on_attach(buf)
local found = false
for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
  if map.lhs == 'o' then found = map.desc == '打开' end
end
check(found, 'real nvim-tree on_attach mapping desc not translated')
vim.api.nvim_exec_autocmds('User', { pattern = 'LazyLoad', data = 'nvim-tree.lua', modeline = false })
equal(require('nvim-zh').info().plugins['nvim-tree'].active, true, 'real LazyLoad integration failed')
local info = require('nvim-zh').info().plugins['nvim-cmp']
check(not info.active and info.reason == 'inventory_only_no_cmp_owned_fixed_labels', 'nvim-cmp exclusion changed')
require('nvim-zh.plugins').teardown()
check(tree.setup == original_tree_setup, 'real nvim-tree teardown failed')
print('ADDITIONAL_UPSTREAM_SMOKE_SPEC=PASS lazy=306a055 nvim-tree=69eb0c3 nvim-cmp=2ffe79f inventory_only=true')
