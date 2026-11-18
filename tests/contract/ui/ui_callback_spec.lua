local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local events = {}
local input_opts_seen
local input_callback_seen
local input_spy = function(opts, on_confirm)
  input_opts_seen = opts
  input_callback_seen = on_confirm
  vim.schedule(function()
    table.insert(events, 'input-callback')
    on_confirm('原始输入')
    vim.schedule(function()
      table.insert(events, 'input-cancel')
      on_confirm(nil)
    end)
  end)
  return 'input-return', 17
end
vim.ui.input = input_spy

local item = { value = 42 }
local items = { item, { value = 99 } }
local select_opts_seen
local select_items_seen
local select_callback_seen
local format_item = function(value) return value == item and 'Ready' or 'Other' end
local preview_item = function() return nil end
local select_spy = function(received_items, opts, on_choice)
  select_items_seen = received_items
  select_opts_seen = opts
  select_callback_seen = on_choice
  equal(opts.format_item(received_items[1]), 'Ready', 'select items translated while disabled')
  vim.schedule(function()
    table.insert(events, 'select-callback')
    on_choice(received_items[1], 1)
    vim.schedule(function()
      table.insert(events, 'select-cancel')
      on_choice(nil, nil)
    end)
  end)
  return 'select-return', 23
end
vim.ui.select = select_spy

h.setup({ notify = false, prompts = true, select_items = false, echo = false })
check(vim.ui.input ~= input_spy and vim.ui.select ~= select_spy, 'UI prompt functions were not wrapped')
local input_wrapper, select_wrapper = vim.ui.input, vim.ui.select
h.setup({ notify = false, prompts = true, select_items = false, echo = false })
check(vim.ui.input == input_wrapper and vim.ui.select == select_wrapper, 'repeated setup stacked UI wrappers')

local original_input_opts = {
  prompt = 'Input:', title = 'Prompt title', default = 'main.cpp', completion = 'file',
  highlight = function() return {} end,
}
local confirmed = 'unset'
local input_callback = function(value) confirmed = value end
local input_returns = pack(vim.ui.input(original_input_opts, input_callback))
equal(input_returns.n, 2, 'input return arity')
equal(input_returns[1], 'input-return', 'input first return')
equal(input_returns[2], 17, 'input second return')
equal(input_opts_seen.prompt, '输入：', 'input prompt')
equal(input_opts_seen.title, '提示标题', 'input title')
check(input_opts_seen ~= original_input_opts, 'input opts must not be mutated in place')
equal(original_input_opts.prompt, 'Input:', 'caller input opts mutated')
check(input_opts_seen.default == original_input_opts.default and input_opts_seen.completion == 'file', 'input default/completion changed')
check(input_opts_seen.highlight == original_input_opts.highlight and input_callback_seen == input_callback, 'input highlight/callback identity changed')
check(vim.wait(1000, function() return #events >= 2 end), 'input callbacks not received')
equal(confirmed, nil, 'input nil cancellation changed')
equal(events[1], 'input-callback', 'input async order')
equal(events[2], 'input-cancel', 'input cancellation order')

local selected, selected_index = 'unset', 'unset'
local select_callback = function(choice, index) selected, selected_index = choice, index end
local original_select_opts = {
  prompt = 'Select one of:', title = 'Prompt title', kind = 'contract',
  format_item = format_item, preview_item = preview_item,
}
local select_returns = pack(vim.ui.select(items, original_select_opts, select_callback))
equal(select_returns.n, 2, 'select return arity')
equal(select_returns[1], 'select-return', 'select first return')
equal(select_returns[2], 23, 'select second return')
check(select_items_seen == items, 'select items identity changed')
equal(select_opts_seen.prompt, '请选择：', 'select prompt')
equal(select_opts_seen.title, '提示标题', 'select title')
check(select_opts_seen ~= original_select_opts, 'select opts must not be mutated in place')
equal(original_select_opts.prompt, 'Select one of:', 'caller select opts mutated')
check(select_opts_seen.kind == 'contract' and select_opts_seen.format_item == format_item, 'select kind/format_item changed')
check(select_opts_seen.preview_item == preview_item and select_callback_seen == select_callback, 'select preview/callback identity changed')
check(vim.wait(1000, function() return #events >= 4 end), 'select callbacks not received')
check(selected == nil and selected_index == nil, 'select nil cancellation changed')
equal(events[3], 'select-callback', 'select async order')
equal(events[4], 'select-cancel', 'select cancellation order')

vim.ui.input({ prompt = '未知提示' }, function() end)
equal(input_opts_seen.prompt, '未知提示', 'unknown input prompt fallback')
vim.ui.select(items, { prompt = 'Unknown prompt', format_item = format_item }, function() end)
equal(select_opts_seen.prompt, 'Unknown prompt', 'unknown select prompt fallback')

h.setup({ notify = false, prompts = false, select_items = false, echo = false })
check(vim.ui.input == input_spy and vim.ui.select == select_spy, 'disabling prompts did not restore originals')
print('UI_CALLBACK_CONTRACT_SPEC=PASS events=' .. table.concat(events, ','))
