local function check(value, message)
  if not value then error(message, 2) end
end
local zh = require('nvim-zh')
zh.setup()
local text, status = zh.translate({ domain = 'nvim-zh', msgid = 'Missing translations' })
check(text == '缺失翻译' and status == 'translated', 'built-in generated PO catalog was not loaded')
local stats = zh.stats()
local found = false
for _, row in ipairs(stats.static.domains) do
  if row.domain == 'nvim-zh' and row.total >= 2 and row.coverage == 1 then found = true end
end
check(found, 'static catalog coverage not reported separately')
print('BUILTIN_CATALOG_SPEC=PASS')
