local adapter = require('nvim-zh.adapters.nvim_cmp')
local enabled, source = true, true
local current = function() return source end
local context = {
  enabled = function() return enabled end,
  verify = function() return true end,
  translate = function(_, key, text) return ('zh/%s/%s'):format(key, text) end,
}
adapter.attach(context)

-- Exercise the same anchored operands as the fixed version without importing a
-- source tree into the offline contract suite.
local lines = {}
for row = 1, 325 do lines[row] = '' end
lines[1] = 'local M = {}; function M.status()'
local groups = { [300] = 'Special', [308] = 'Comment', [316] = 'WarningMsg', [324] = 'ErrorMsg' }
for row, title in pairs({ [300] = 'ready', [308] = 'unavailable', [316] = 'unused', [324] = 'unknown' }) do
  lines[row] = ("vim.api.nvim_echo({ { '# %s source names\\n', '%s' } }, false, {})"):format(title, groups[row])
end
lines[325] = 'end; return M'
local instance = adapter.project_source('cmp', table.concat(lines, '\n'), '@fixed-cmp', current)()
local messages = {}
local echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, opts)
  assert(history == false and next(opts) == nil)
  messages[#messages + 1] = chunks[1]
end
instance.status()
assert(messages[1][1] == '# zh/status/ready source names\n' and messages[1][2] == 'Special')
enabled = false
instance.status()
assert(messages[5][1] == '# ready source names\n')
enabled, source = true, false
instance.status()
assert(messages[9][1] == '# ready source names\n')
source = true
local retained = instance.status
instance.status = function() return 'external' end
retained()
assert(messages[13][1] == '# ready source names\n' and instance.status() == 'external')
adapter.detach()
assert(not pcall(adapter.project_source, 'cmp', 'return {}', '@wrong-cmp', current))
vim.api.nvim_echo = echo
print('NVIM_CMP_CONTRACT=PASS source ownership disabled retained callback fixed operands')
