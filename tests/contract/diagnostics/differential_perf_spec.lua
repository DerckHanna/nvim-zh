local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local original = { message = "Redefinition of 'x'", source = 'clangd' }
local user_calls = 0
local function user_format(diagnostic)
  user_calls = user_calls + 1
  if diagnostic.message == 'boom' then error('differential-user-format-error') end
  return diagnostic.message
end
vim.diagnostic.config({ virtual_text = { format = user_format }, virtual_lines = false, float = false })
local iterations = 5000
local clock = vim.uv.hrtime
local function measure(format)
  local start = clock()
  for _ = 1, iterations do format(original) end
  return (clock() - start) / 1000 / iterations
end
h.setup({ enabled = false })
local baseline = vim.diagnostic.config().virtual_text.format
equal(baseline(original), original.message, 'baseline formatter return')
h.setup()
local translated = vim.diagnostic.config().virtual_text.format
local before = user_calls
equal(translated(original), "'x' 重复定义", 'translated formatter return')
equal(user_calls, before + 1, 'user formatter was dropped or called more than once')
equal(translated({ message = 'unknown diagnostic', source = 'clangd' }), 'unknown diagnostic', 'unknown fallback return')
equal(translated({ message = original.message, source = 'other-server' }), original.message, 'other server return')
local baseline_ok, baseline_err = pcall(baseline, { message = 'boom' })
local translated_ok, translated_err = pcall(translated, { message = 'boom', source = 'clangd' })
equal(translated_ok, baseline_ok, 'formatter error status changed')
check(not translated_ok and tostring(translated_err):find('differential-user-format-error', 1, true),
  'formatter error was swallowed or replaced')
check(tostring(baseline_err):find('differential-user-format-error', 1, true), 'baseline error fixture failed')
for _ = 1, 100 do translated(original) end
local baseline_us = measure(baseline)
local hit_us = measure(translated)
local miss_us = measure(function() return translated({ message = 'unknown diagnostic', source = 'clangd' }) end)
print(('DIAGNOSTIC_ADAPTER_PERF baseline_us=%.3f cache_hit_us=%.3f cache_miss_us=%.3f iterations=%d'):format(baseline_us, hit_us, miss_us, iterations))
print('DIAGNOSTIC_DIFFERENTIAL_SPEC=PASS formatter_returns_and_errors=preserved')
