local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check = h.check

local notify_calls = {}
local input_calls, select_calls, echo_calls = {}, {}, {}
local once_seen = {}
vim.notify = function(msg, level, opts)
  table.insert(notify_calls, { msg = msg, level = level, opts = opts })
  return 'notify-return', 7
end
vim.notify_once = function(msg, level, opts)
  if once_seen[msg] then return false end
  once_seen[msg] = true
  vim.notify(msg, level, opts)
  return true
end
vim.ui.input = function(opts, callback)
  table.insert(input_calls, { opts = opts, callback = callback })
  vim.schedule(function() callback('raw-input') end)
  return 'input-return', 11
end
vim.ui.select = function(items, opts, callback)
  table.insert(select_calls, { items = items, opts = opts, callback = callback })
  vim.schedule(function() callback(items[1], 1) end)
  return 'select-return', 13
end
vim.api.nvim_echo = function(chunks, history, opts)
  table.insert(echo_calls, { chunks = chunks, history = history, opts = opts })
  return 'message-id'
end

local opts = { title = 'Prompt title', data = { unchanged = true } }
local item = { id = 42 }
local input_value, selected, selected_index
local input_callback = function(value) input_value = value end
local select_callback = function(value, index) selected, selected_index = value, index end
local echo_opts = { id = 'differential', kind = 'contract' }

local function run()
  notify_calls, input_calls, select_calls, echo_calls = {}, {}, {}, {}
  once_seen = {}
  input_value, selected, selected_index = nil, nil, nil
  local returns = { notify = h.pack(vim.notify('Ready', vim.log.levels.WARN, opts)) }
  returns.once = {
    vim.notify_once('Ready', vim.log.levels.INFO, opts),
    vim.notify_once('Ready', vim.log.levels.INFO, opts),
    vim.notify_once('Done', vim.log.levels.INFO, opts),
  }
  returns.input = h.pack(vim.ui.input({ prompt = 'Input:', title = 'Prompt title', default = 'raw' }, input_callback))
  returns.select = h.pack(vim.ui.select({ item }, {
    prompt = 'Select one of:', title = 'Prompt title', kind = 'contract',
  }, select_callback))
  returns.echo = h.pack(vim.api.nvim_echo({ { 'Echo ready', 'WarningMsg', extra = opts.data } }, true, echo_opts))
  check(vim.wait(1000, function() return input_value ~= nil and selected ~= nil end), 'differential callbacks missing')
  return {
    notify = notify_calls,
    input = input_calls,
    select = select_calls,
    echo = echo_calls,
    returns = returns,
    input_value = input_value,
    selected_same = selected == item,
    selected_index = selected_index,
    input_opts_unchanged = input_calls[1].opts.default == 'raw',
    select_items_same = select_calls[1].items[1] == item,
  }
end

require('nvim-zh').setup({ modules = { ui = { notify = false, prompts = false, echo = false } }, overrides = h.ui_overrides() })
local baseline = run()
require('nvim-zh').setup({ modules = { ui = { notify = true, prompts = true, echo = true } }, overrides = h.ui_overrides() })
local translated = run()

local function normalize(result)
  for _, call in ipairs(result.notify) do call.msg = '<display>' end
  for _, call in ipairs(result.input) do
    call.opts.prompt, call.opts.title = '<display>', '<display>'
  end
  for _, call in ipairs(result.select) do
    call.opts.prompt, call.opts.title = '<display>', '<display>'
  end
  for _, call in ipairs(result.echo) do call.chunks[1][1] = '<display>' end
end
normalize(baseline)
normalize(translated)
check(vim.deep_equal(baseline, translated), 'non-display observable behavior differs:\n' .. vim.inspect({ baseline = baseline, translated = translated }))
print('DIFFERENTIAL_CONTRACT_SPEC=PASS notify,notify_once,input,select,echo non_display=identical')
