local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local stored, calls = nil, 0
vim.ui.select = function(_, opts) stored = opts end
local function formatter(item) calls = calls + 1; return item.text end
local item = { text = 'Ready' }
h.setup({ notify = false, prompts = true, select_items = true, echo = false })
vim.ui.select({ item }, { format_item = formatter }, function() end)
local retained = stored.format_item
h.equal(retained(item), '选项就绪', 'active retained formatter')
for _, options in ipairs({
  { notify = false, prompts = true, select_items = false, echo = false },
  { notify = false, prompts = false, select_items = true, echo = false },
}) do
  h.setup(options)
  local before = calls
  h.equal(retained(item), 'Ready', 'disabled retained formatter still translated')
  h.equal(calls, before + 1, 'original formatter call count changed')
end
require('nvim-zh.ui').teardown()
h.equal(retained(item), 'Ready', 'teardown left retained formatter active')
print('RETAINED_ITEMS_SPEC=PASS switches teardown original_formatter')
