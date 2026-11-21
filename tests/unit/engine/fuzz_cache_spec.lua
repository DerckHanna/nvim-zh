local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then error(message .. ': ' .. tostring(actual), 2) end
end
local zh = require('nvim-zh')
local domain = 'fuzz-fixture'
zh.register_catalog(domain, function()
  return { schema = 1, domain = domain, locale = 'zh_CN', entries = {
    { context = '', msgid = '你好 🌏\nsecond', msgstr = '中文 🌏\n第二行' },
    { context = '', msgid = 'Line {value}\nEnd', msgstr = '行 {value}\n结束' },
    { context = '', msgid = 'Bad %s', msgstr = '错误 %d' },
  } }
end)
zh.setup({ modules = { core = { enabled = false } }, missing = { max_entries = 32 } })
equal(zh.translate({ domain = domain, msgid = '你好 🌏\nsecond' }), '中文 🌏\n第二行', 'Unicode/newline exact')
equal(zh.translate({ domain = domain, msgid = '' }), '', 'empty string changed')
equal(zh.translate({ domain = domain, msgid = 'Line 一🌏\n二\nEnd', formatted = true }), '行 一🌏\n二\n结束', 'Unicode/newline template')
local long = string.rep('长🌏abc%{}', 10000)
equal(zh.translate({ domain = domain, msgid = long, formatted = true }), long, 'long input changed')
equal(zh.translate({ domain = domain, msgid = '100% {not closed', formatted = true }), '100% {not closed', 'placeholder-like input changed')
equal(zh.translate({ domain = domain, msgid = 'Bad %s', args = { 'x' } }), 'Bad %s', 'invalid placeholder pair translated')
equal(zh.translate({ domain = domain, msgid = 'Bad value', formatted = true }), 'Bad value', 'invalid formatted placeholder pair translated')

local conflict = 'conflict-fixture'
zh.register_catalog(conflict, function()
  return { schema = 1, domain = conflict, locale = 'zh_CN', entries = {
    { context = '', msgid = 'Value {first}', msgstr = '值 {first}' },
    { context = '', msgid = 'Value {second}', msgstr = '数值 {second}' },
  } }
end)
equal(zh.translate({ domain = conflict, msgid = 'Value x', formatted = true }), 'Value x', 'ambiguous templates must fall back')
zh.register_catalog('duplicate-fixture', function()
  return { schema = 1, domain = 'duplicate-fixture', locale = 'zh_CN', entries = {
    { context = '', msgid = 'Same', msgstr = '一' },
    { context = '', msgid = 'Same', msgstr = '二' },
  } }
end)
equal(zh.translate({ domain = 'duplicate-fixture', msgid = 'Same' }), 'Same', 'duplicate catalog key did not fall back')

local perf_domain = 'performance-fixture'
local perf_loads = 0
zh.register_catalog(perf_domain, function()
  perf_loads = perf_loads + 1
  local entries = {}
  for index = 1, 100 do
    table.insert(entries, { context = '', msgid = 'Message ' .. index, msgstr = '消息 ' .. index })
  end
  return { schema = 1, domain = perf_domain, locale = 'zh_CN', entries = entries }
end)
local clock = vim.uv.hrtime
local cold_start = clock()
equal(zh.translate({ domain = perf_domain, msgid = 'Message 1' }), '消息 1', 'cold translation')
local cold_ns = clock() - cold_start
local iterations = 5000
local hit_start = clock()
for _ = 1, iterations do
  equal(zh.translate({ domain = perf_domain, msgid = 'Message 100' }), '消息 100', 'cached hit')
end
local hit_ns = clock() - hit_start
local miss_start = clock()
for _ = 1, iterations do
  equal(zh.translate({ domain = perf_domain, msgid = 'Not translated', formatted = true }), 'Not translated', 'cached miss')
end
local miss_ns = clock() - miss_start
equal(perf_loads, 1, 'performance catalog load count')
print(('ENGINE_PERF cold_load_us=%.2f cache_hit_us=%.3f cache_miss_us=%.3f iterations=%d'):format(
  cold_ns / 1000, hit_ns / iterations / 1000, miss_ns / iterations / 1000, iterations))
print('FUZZ_PERF_SPEC=PASS')
