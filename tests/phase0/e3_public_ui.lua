local function check(value, message)
  if not value then error(message, 2) end
end
local translations = { Ready = '就绪', Done = '就绪', ['Select one of:'] = '请选择：', ['Input:'] = '输入：' }
local function translate(text) return translations[text] or text end

-- vim.notify contract and notify_once's original-message deduplication.
local notify_calls = {}
local notify_spy = function(msg, level, opts)
  table.insert(notify_calls, { msg = msg, level = level, opts = opts })
  return 'notify-return'
end
vim.notify = notify_spy
local previous_notify = vim.notify
vim.notify = function(msg, level, opts) return previous_notify(translate(msg), level, opts) end
local opts = { title = 'contract' }
check(vim.notify('Ready', vim.log.levels.WARN, opts) == 'notify-return', 'notify return changed')
check(notify_calls[1].msg == '就绪' and notify_calls[1].opts == opts, 'notify arguments changed')
check(vim.notify_once('Ready') == true, 'first notify_once was not displayed')
check(vim.notify_once('Ready') == false, 'notify_once deduplication changed')
check(vim.notify_once('Done') == true, 'dedup key changed from source to translation')
check(#notify_calls == 3, 'notify call count mismatch')

-- vim.ui.select: translate only prompt, preserve item/callback and async timing.
local select_spy = function(items, select_opts, on_choice)
  check(select_opts.prompt == '请选择：', 'select prompt not translated')
  check(select_opts.kind == 'contract', 'select kind changed')
  vim.schedule(function() on_choice(items[1], 1) end)
  return 'select-return'
end
vim.ui.select = select_spy
local previous_select = vim.ui.select
vim.ui.select = function(items, select_opts, on_choice)
  local copy = vim.tbl_extend('force', {}, select_opts, { prompt = translate(select_opts.prompt) })
  return previous_select(items, copy, on_choice)
end
local item = { value = 42 }
local selected
local ret = vim.ui.select({ item }, { prompt = 'Select one of:', kind = 'contract' }, function(choice, idx)
  selected = { choice = choice, idx = idx }
end)
check(ret == 'select-return', 'select return changed')
check(vim.wait(1000, function() return selected ~= nil end), 'async select callback not received')
check(selected.choice == item and selected.idx == 1, 'select item/index identity changed')

-- vim.ui.input: prompt only; input/default/completion remain untouched.
local input_spy = function(input_opts, on_confirm)
  check(input_opts.prompt == '输入：' and input_opts.default == 'main.cpp', 'input options changed')
  check(input_opts.completion == 'file', 'input completion changed')
  on_confirm('user-input')
  return 'input-return'
end
vim.ui.input = input_spy
local previous_input = vim.ui.input
vim.ui.input = function(input_opts, on_confirm)
  local copy = vim.tbl_extend('force', {}, input_opts, { prompt = translate(input_opts.prompt) })
  return previous_input(copy, on_confirm)
end
local confirmed
check(vim.ui.input({ prompt = 'Input:', default = 'main.cpp', completion = 'file' }, function(value)
  confirmed = value
end) == 'input-return', 'input return changed')
check(confirmed == 'user-input', 'input callback value changed')

-- nvim_echo is technically composable, but remains opt-in in the design.
local echo_args
vim.api.nvim_echo = function(chunks, history, echo_opts)
  echo_args = { chunks = chunks, history = history, opts = echo_opts }
  return 'message-id'
end
local previous_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, echo_opts)
  local copy = vim.deepcopy(chunks)
  copy[1][1] = translate(copy[1][1])
  return previous_echo(copy, history, echo_opts)
end
local echo_opts = { kind = 'contract' }
check(vim.api.nvim_echo({ { 'Ready', 'WarningMsg' } }, true, echo_opts) == 'message-id', 'echo id changed')
check(echo_args.chunks[1][1] == '就绪' and echo_args.chunks[1][2] == 'WarningMsg', 'echo chunk/highlight changed')
check(echo_args.history == true and echo_args.opts == echo_opts, 'echo history/options changed')
print('E3_PUBLIC_UI_STATUS=PASS notify=3_calls dedup=source select=identity input=identity echo=id_preserved')
