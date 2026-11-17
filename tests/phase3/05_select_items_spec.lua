local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase3/helpers.lua')
local check, equal = h.check, h.equal

local item = { value = 42 }
local items = { item }
local observed_items, observed_opts
local expected_display = '选项就绪'
local original_format = function(value)
  check(value == item, 'format_item received a mapped/display item instead of original')
  return 'Ready'
end
local select_spy = function(received_items, opts, on_choice)
  observed_items, observed_opts = received_items, opts
  equal(opts.format_item(item), expected_display, 'select item display policy')
  vim.schedule(function() on_choice(received_items[1], 1) end)
  return 'select-return'
end
vim.ui.select = select_spy
h.setup({ notify = false, prompts = true, select_items = true, echo = false })
check(require('nvim-zh').info().ui.select_items.active == true, 'select_items active status missing')
local caller_opts = { prompt = 'Select one of:', format_item = original_format, kind = 'items' }
local selected, index
equal(vim.ui.select(items, caller_opts, function(choice, idx) selected, index = choice, idx end), 'select-return', 'select return')
check(observed_items == items, 'select item list replaced')
check(observed_opts.format_item ~= original_format, 'format_item was not wrapped')
check(caller_opts.format_item == original_format, 'caller format_item mutated')
check(vim.wait(1000, function() return selected ~= nil end), 'select callback not called')
check(selected == item and index == 1, 'select item identity/index changed with display translation')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('item translation error') end
equal(observed_opts.format_item(item), 'Ready', 'item translation exception fallback')
engine.translate = original_translate

expected_display = 'Ready'
h.setup({ notify = false, prompts = true, select_items = false, echo = false })
vim.ui.select(items, caller_opts, function() end)
check(observed_opts.format_item == original_format, 'disabling select_items did not restore formatter')
equal(observed_opts.format_item(item), 'Ready', 'disabled item formatter translated')
print('SELECT_ITEMS_SPEC=PASS identity=original mapping=format_item')
