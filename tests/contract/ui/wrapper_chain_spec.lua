local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal = h.check, h.equal

local seen = { input = {}, select = {}, echo = {} }
vim.ui.input = function(opts, on_confirm) table.insert(seen.input, opts.prompt) on_confirm('raw') return 'input' end
vim.ui.select = function(items, opts, on_choice) table.insert(seen.select, opts.prompt) on_choice(items[1], 1) return 'select' end
vim.api.nvim_echo = function(chunks, history, opts)
  table.insert(seen.echo, { chunks = chunks, history = history, opts = opts })
  return 'echo-id'
end
h.setup({ notify = false, prompts = true, select_items = false, echo = true })
local ours = { input = vim.ui.input, select = vim.ui.select, echo = vim.api.nvim_echo }
local external = {
  input = function(opts, callback) return ours.input(opts, callback) end,
  select = function(items, opts, callback) return ours.select(items, opts, callback) end,
  echo = function(chunks, history, opts) return ours.echo(chunks, history, opts) end,
}
vim.ui.input, vim.ui.select, vim.api.nvim_echo = external.input, external.select, external.echo
dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
check(vim.ui.input == external.input and vim.ui.select == external.select, 'reload stole external prompt wrappers')
check(vim.api.nvim_echo == external.echo, 'reload stole external echo wrapper')
vim.ui.input({ prompt = 'Input:' }, function() end)
vim.ui.select({ 'raw-item' }, { prompt = 'Select one of:' }, function() end)
vim.api.nvim_echo({ { 'Echo ready', 'WarningMsg' } }, true, { id = 'chain' })
equal(seen.input[#seen.input], '输入：', 'external input chain')
equal(seen.select[#seen.select], '请选择：', 'external select chain')
equal(seen.echo[#seen.echo].chunks[1][1], '回显就绪', 'external echo chain')

require('nvim-zh.ui').teardown()
check(vim.ui.input == external.input and vim.ui.select == external.select, 'teardown overwrote external prompt wrappers')
check(vim.api.nvim_echo == external.echo, 'teardown overwrote external echo wrapper')
vim.ui.input({ prompt = 'Input:' }, function() end)
vim.ui.select({ 'raw-item' }, { prompt = 'Select one of:' }, function() end)
vim.api.nvim_echo({ { 'Echo ready', 'WarningMsg' } }, false, {})
equal(seen.input[#seen.input], 'Input:', 'stale input wrapper remained active after teardown')
equal(seen.select[#seen.select], 'Select one of:', 'stale select wrapper remained active after teardown')
equal(seen.echo[#seen.echo].chunks[1][1], 'Echo ready', 'stale echo wrapper remained active after teardown')
print('UI_WRAPPER_CHAIN_SPEC=PASS prompts_and_echo=external_after')
