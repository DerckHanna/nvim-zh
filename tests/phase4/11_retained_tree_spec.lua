local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local stored, desc, original_calls = nil, nil, 0
local keymap = function(_, _, _, opts) desc = opts.desc end
vim.keymap.set = keymap
package.loaded['nvim-tree'] = { setup = function(opts) stored = opts end }
h.setup()
package.loaded['nvim-tree'].setup({ on_attach = function(buf)
  original_calls = original_calls + 1
  vim.keymap.set('n', 'o', '<Nop>', { desc = 'Open', buffer = buf })
  return buf, nil, 'tail'
end })
local retained = stored.on_attach
retained(1)
h.equal(desc, '打开', 'active tree callback')
for _, opts in ipairs({ { auto = true, disabled = { 'nvim-tree' } }, { auto = false, disabled = {} } }) do
  h.setup(opts)
  local before = original_calls
  local values = h.pack(retained(2))
  h.equal(desc, 'Open', 'disabled tree callback still translated')
  h.equal(original_calls, before + 1, 'disabled callback original call count')
  h.equal(values.n, 3, 'on_attach return arity')
  h.equal(values[3], 'tail', 'on_attach return values')
  h.equal(vim.keymap.set, keymap, 'disabled callback changed keymap.set')
end
require('nvim-zh.plugins').teardown()
retained(3)
h.equal(desc, 'Open', 'teardown left tree callback active')
print('RETAINED_TREE_SPEC=PASS switches teardown return_values keymap_ownership')
