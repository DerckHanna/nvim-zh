local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check = h.check
local original_keymap_set = vim.keymap.set
local desc, original_calls = nil, 0
local throw_default = false
local keymap_spy = function(_, _, _, opts)
  desc = opts.desc
  return 'map-return'
end
vim.keymap.set = keymap_spy

local rhs = function() end
local keymap = {}
keymap.on_attach_default = function(bufnr)
  original_calls = original_calls + 1
  if throw_default then error('default-on-attach-error') end
  vim.keymap.set('n', 'o', rhs, { desc = 'nvim-tree: Open', buffer = bufnr })
  return bufnr, nil, 'tail'
end
local original_default = keymap.on_attach_default
package.loaded['nvim-tree.keymap'] = keymap
package.loaded['nvim-tree.config'] = { g = { on_attach = 'default' } }
package.loaded['nvim-tree'] = { setup = function() end }

local overrides = h.overrides()
overrides['nvim-tree'] = { mapping = { Open = '打开' } }
h.setup({ auto = true, disabled = {} }, overrides)
local retained = keymap.on_attach_default
check(retained ~= original_default, 'retained default callback was never wrapped')

local values = h.pack(retained(1))
h.equal(values.n, 3, 'active default callback return arity')
h.equal(values[1], 1, 'active default callback first return')
h.equal(values[3], 'tail', 'active default callback tail return')
h.equal(desc, 'nvim-tree: 打开', 'active default callback translation')
h.equal(vim.keymap.set, keymap_spy, 'active callback changed keymap.set ownership')

for _, opts in ipairs({ { auto = true, disabled = { 'nvim-tree' } }, { auto = false, disabled = {} } }) do
  h.setup(opts, overrides)
  local before = original_calls
  values = h.pack(retained(2))
  h.equal(desc, 'nvim-tree: Open', 'disabled retained callback still translated')
  h.equal(original_calls, before + 1, 'disabled retained callback original call count')
  h.equal(values.n, 3, 'disabled retained callback return arity')
  h.equal(values[3], 'tail', 'disabled retained callback return values')
  h.equal(vim.keymap.set, keymap_spy, 'disabled retained callback changed keymap.set')
  h.equal(keymap.on_attach_default, original_default, 'disable did not restore live default callback')
end

h.setup({ auto = true, disabled = {} }, overrides)
throw_default = true
local ok, err = pcall(retained, 3)
throw_default = false
check(not ok and tostring(err):find('default-on-attach-error', 1, true), 'default callback error swallowed')
h.equal(vim.keymap.set, keymap_spy, 'keymap.set leaked after default callback error')

require('nvim-zh.plugins').teardown()
local before = original_calls
retained(4)
h.equal(desc, 'nvim-tree: Open', 'teardown left retained callback active')
h.equal(original_calls, before + 1, 'teardown retained callback original call count')
h.equal(keymap.on_attach_default, original_default, 'teardown did not restore live default callback')
vim.keymap.set = original_keymap_set
print('RETAINED_TREE_SPEC=PASS switches teardown return_values error_restore keymap_ownership')
