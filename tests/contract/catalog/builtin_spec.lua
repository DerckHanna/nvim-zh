local zh = require('nvim-zh')
zh.setup({ modules = { core = { enabled = false } } })
local domains = require('nvim-zh.catalog').builtin_domains()
assert(vim.deep_equal(domains, { 'nvim-ui' }))
assert(not next(zh.status().adapters) and not next(zh.status().packs), 'clean setup installed optional packs')
local text, status = zh.translate({ domain = 'nvim-ui', msgid = 'No information available' })
assert(text == '没有可用的信息' and status == 'translated', 'production catalog unavailable')
local found = false
for _, row in ipairs(zh.stats().static.domains) do
  assert(row.coverage == nil and row.total == nil, 'inventory claims coverage')
  if row.domain == 'nvim-ui' and row.entries > 0 then found = true end
end
assert(found, 'loaded catalog inventory missing')
for _, msgid in ipairs({ 'Ready', 'Done', 'Echo ready' }) do
  local source, result = zh.translate({ domain = 'nvim-ui', msgid = msgid })
  assert(source == msgid and result == 'fallback', 'test fixture shipped in production')
end
assert(zh.translate({ domain = 'nvim-zh', msgid = 'Missing translations' }) == 'Missing translations')
print(('BUILTIN_CATALOG_SPEC=PASS production_domains=%d inventory_only fixture_free'):format(#domains))
