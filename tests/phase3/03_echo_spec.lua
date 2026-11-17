local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase3/helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local calls = {}
local throw_original = false
local echo_spy = function(chunks, history, opts)
  table.insert(calls, { chunks = chunks, history = history, opts = opts })
  if throw_original then error('original-echo-error') end
  return 'message-id', 31
end
vim.api.nvim_echo = echo_spy
local original_out_write = vim.api.nvim_out_write
h.setup({ notify = false, prompts = false, echo = false })
check(vim.api.nvim_echo == echo_spy, 'echo must be disabled by default')
h.setup({ notify = false, prompts = false, echo = true })
check(vim.api.nvim_echo ~= echo_spy, 'opt-in echo was not wrapped')
check(vim.api.nvim_out_write == original_out_write, 'output stream must not be wrapped')

local metadata = { source = 'chunk-meta' }
local original_chunks = {
  { 'Echo ready', 'WarningMsg', metadata = metadata },
  { 42, 'Number', metadata = metadata },
  { 'Unknown echo', 'Comment' },
}
local original_opts = { id = 'nvim-zh.test', kind = 'progress', data = { percent = 10 } }
local returns = pack(vim.api.nvim_echo(original_chunks, true, original_opts))
equal(returns.n, 2, 'echo return arity')
equal(returns[1], 'message-id', 'echo message id')
equal(returns[2], 31, 'echo second return')
local observed = calls[#calls]
check(observed.chunks ~= original_chunks, 'echo chunks mutated in place')
equal(original_chunks[1][1], 'Echo ready', 'caller echo chunk mutated')
equal(observed.chunks[1][1], '回显就绪', 'echo text translation')
equal(observed.chunks[1][2], 'WarningMsg', 'echo highlight')
check(observed.chunks[1].metadata == metadata, 'echo chunk metadata lost')
equal(observed.chunks[2][1], 42, 'non-string echo chunk changed')
check(observed.chunks[2].metadata == metadata, 'non-string chunk metadata lost')
equal(observed.chunks[3][1], 'Unknown echo', 'unknown echo fallback')
equal(observed.chunks[3][2], 'Comment', 'unknown echo highlight')
check(observed.history == true and observed.opts == original_opts, 'echo history/opts identity changed')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('echo translation exploded') end
vim.api.nvim_echo({ { 'Echo ready', 'ErrorMsg' } }, false, {})
equal(calls[#calls].chunks[1][1], 'Echo ready', 'echo translation exception fallback')
engine.translate = original_translate

throw_original = true
local ok, err = pcall(vim.api.nvim_echo, { { 'Echo ready' } }, false, {})
throw_original = false
check(not ok and tostring(err):find('original-echo-error', 1, true), 'original echo exception was swallowed')

local original_in_fast_event = vim.in_fast_event
vim.in_fast_event = function() return true end
engine.translate = function() error('fast event must not translate') end
local fast_chunks = { { 'Echo ready', 'WarningMsg', metadata = metadata } }
local fast_returns = pack(vim.api.nvim_echo(fast_chunks, false, original_opts))
equal(fast_returns[1], 'message-id', 'fast echo return')
check(calls[#calls].chunks == fast_chunks, 'fast echo did not call original directly')
equal(calls[#calls].chunks[1][1], 'Echo ready', 'fast echo translated text')
engine.translate = original_translate
vim.in_fast_event = original_in_fast_event

h.setup({ notify = false, prompts = false, echo = false })
check(vim.api.nvim_echo == echo_spy, 'disabling echo did not restore original')
print('ECHO_CONTRACT_SPEC=PASS calls=' .. #calls)
