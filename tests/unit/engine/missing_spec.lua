local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then error(('%s: expected %s, got %s'):format(message, tostring(expected), tostring(actual)), 2) end
end
local zh = require('nvim-zh')
local domain = 'missing-fixture'
zh.register_catalog(domain, function()
  return { schema = 1, domain = domain, locale = 'zh_CN', entries = {
    { context = '', msgid = 'Known', msgstr = '已知' },
    { context = '', msgid = 'Known {name}', msgstr = '已知 {name}' },
  } }
end)
zh.setup({ modules = { core = { enabled = false } }, missing = { enabled = true, max_entries = 2 } })
local missing = require('nvim-zh.missing')
missing.reset()
zh.translate({ domain = domain, msgid = 'Known' })
zh.translate({ domain = domain, msgid = 'Absent' })
zh.translate({ domain = domain, msgid = 'Absent' })
zh.translate({ domain = domain, context = 'ctx', msgid = 'Absent' })
local stats = zh.stats()
equal(stats.missing.unique, 2, 'deduplicated unique misses')
equal(stats.missing.occurrences, 3, 'miss occurrences')
equal(stats.runtime.observed, 4, 'runtime observation count')
equal(stats.runtime.translated, 1, 'runtime translated count')
equal(stats.runtime.unique, 3, 'runtime unique count')
local rows = missing.list()
equal(#rows, 2, 'missing rows')
local found
for _, row in ipairs(rows) do
  check(row.domain == domain and type(row.context) == 'string', 'row identity missing')
  check(type(row.key) == 'string' and row.count >= 1, 'row key/count missing')
  if row.context == '' then found = row end
end
equal(found and found.count, 2, 'duplicate miss count')

local secret = '/home/alice/private/project/file.lua'
zh.translate({ domain = domain, msgid = 'Cannot read ' .. secret, formatted = true })
local rendered = vim.inspect(missing.list())
check(not rendered:find(secret, 1, true), 'dynamic path leaked into missing report')
zh.translate({ domain = domain, msgid = 'Third absent' })
stats = zh.stats()
check(stats.missing.unique <= 2, 'missing capacity exceeded')
check(stats.missing.dropped >= 1, 'capacity eviction not reported')
missing.reset()
zh.translate({ domain = domain, msgid = 'Known {name}', args = { name = 'Alice' } })
equal(zh.stats().missing.occurrences, 0, 'successful dynamic translation recorded as missing')
zh.translate({ domain = domain, msgid = 'Static path ' .. secret })
check(not vim.inspect(missing.list()):find(secret, 1, true), 'static path leaked into missing report')
missing.reset()
zh.translate({ domain = domain, msgid = string.rep('x', 2048) })
check(#missing.list()[1].msgid < 100, 'very long source text was retained in missing report')
zh.setup({ modules = { core = { enabled = false } }, missing = { enabled = false } })
local before_disabled = zh.stats().missing.occurrences
zh.translate({ domain = domain, msgid = 'Not observed' })
equal(zh.stats().missing.occurrences, before_disabled, 'disabled missing stats still observed')
print('MISSING_SPEC=PASS capacity=' .. tostring(stats.missing.capacity))
