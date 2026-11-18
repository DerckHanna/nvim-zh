local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal = h.check, h.equal

local notify_calls = 0
local last_message
local notify_spy = function(msg)
  notify_calls = notify_calls + 1
  last_message = msg
  return true
end
vim.notify = notify_spy
vim.ui.input = function(opts, on_confirm)
  on_confirm(opts.default)
  return true
end
vim.ui.select = function(items, opts, on_choice)
  on_choice(items[1], 1)
  return true
end
h.setup({ notify = true, prompts = true, select_items = false, echo = false })

local samples = {
  '',
  '你好 🌏',
  'first line\nsecond line\n',
  string.rep('long-文本-', 12000),
  'Not a template %s {name} %%',
  'Loaded',
  'Opened',
  42,
  nil,
}
for _, sample in ipairs(samples) do
  vim.notify(sample)
  check(last_message == sample, 'fuzzy notify input changed for ' .. vim.inspect(sample))
end
-- ipairs stops at nil; exercise it explicitly as an invalid-but-observable call.
vim.notify(nil)
check(last_message == nil, 'nil notify message changed')

local long_prompt = string.rep('提示🌏', 5000)
local input_value
vim.ui.input({ prompt = long_prompt, default = '原始值' }, function(value) input_value = value end)
equal(input_value, '原始值', 'long prompt changed input value')
local original_item = { text = 'Ready' }
local selected, selected_index
vim.ui.select({ original_item }, { prompt = long_prompt }, function(item, index) selected, selected_index = item, index end)
check(selected == original_item and selected_index == 1, 'fuzzy select changed item/index')

local clock = vim.uv and vim.uv.hrtime or vim.loop.hrtime
local iterations = 5000
local function measure(message)
  local started = clock()
  for _ = 1, iterations do vim.notify(message) end
  return (clock() - started) / 1000
end
h.setup({ notify = false, prompts = false, select_items = false, echo = false })
for _ = 1, 100 do vim.notify('Ready') end
local baseline_us = measure('Ready') / iterations
h.setup({ notify = true, prompts = false, select_items = false, echo = false })
for _ = 1, 100 do
  vim.notify('Ready')
  vim.notify('Performance cache miss')
end
local hit_us = measure('Ready') / iterations
local miss_us = measure('Performance cache miss') / iterations
print(('UI_ADAPTER_PERF baseline_us=%.3f cache_hit_us=%.3f cache_miss_us=%.3f iterations=%d'):format(
  baseline_us, hit_us, miss_us, iterations))
print('UI_FUZZ_PERF_SPEC=PASS samples=' .. (#samples + 1))
