local events = {}
local original_cmdheight = vim.o.cmdheight
local ns = vim.api.nvim_create_namespace('nvim-zh-ui-observer')
local iterations = 200
local attach_options = { ext_messages = true }
-- set_cmdheight was added after 0.11; 0.11 rejects the unknown key.
if vim.fn.has('nvim-0.12') == 1 then attach_options.set_cmdheight = false end
vim.ui_attach(ns, attach_options, function(event, ...)
  if event ~= 'msg_show' then return nil end
  local kind, content, replace_last = ...
  local texts = {}
  for _, chunk in ipairs(content) do table.insert(texts, chunk[2]) end
  table.insert(events, {
    kind = kind,
    text = table.concat(texts),
    replace_last = replace_last,
    fast = vim.in_fast_event(),
  })
  return nil -- observe only: never consume or rewrite the event.
end)
vim.cmd('echomsg "NvimZhInternalProbe"')
vim.api.nvim_echo({ { 'NvimZhApiProbe', 'WarningMsg' } }, true, {})
local before = #events
local start = vim.uv.hrtime()
for _ = 1, iterations do vim.api.nvim_echo({ { 'x' } }, false, {}) end
local observed_ns = vim.uv.hrtime() - start
vim.ui_detach(ns)

-- Detach before assertions/history access: in this experimental mode an error
-- or :messages while attached can terminate a headless -l script without a
-- useful error message.
local function check(value, message)
  if not value then error(message, 2) end
end
check(#events >= 2, 'probe msg_show events not observed')
check(#events >= before + iterations, 'observed events were not delivered')
local history = vim.fn.execute('messages')
check(history:find('NvimZhInternalProbe', 1, true) ~= nil, 'internal message missing from history')
check(history:find('NvimZhApiProbe', 1, true) ~= nil, 'API message missing from history')
check(vim.o.cmdheight == original_cmdheight, 'observer changed cmdheight')

start = vim.uv.hrtime()
for _ = 1, iterations do vim.api.nvim_echo({ { 'x' } }, false, {}) end
local baseline_ns = vim.uv.hrtime() - start
local fast_count = 0
for _, event in ipairs(events) do if event.fast then fast_count = fast_count + 1 end end
local status_line = ('E4_UI_ATTACH_STATUS=PASS events=%d fast_events=%d history=preserved cmdheight=preserved'):format(#events, fast_count)
local performance_line = ('E4_PERFORMANCE iterations=%d baseline_ms=%.3f observed_ms=%.3f ratio=%.2f'):format(
  iterations, baseline_ns / 1e6, observed_ns / 1e6, observed_ns / math.max(baseline_ns, 1))
vim.fn.writefile({ status_line, performance_line }, vim.env.NVIM_ZH_TMP .. '/e4.result')
