local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %q, got %q'):format(message, tostring(expected), tostring(actual)), 2)
  end
end

local zh = require('nvim-zh')
local catalog = require('nvim-zh.catalog')
local domain = 'engine-fixture'
local loads = 0
local function loader()
  loads = loads + 1
  return {
    schema = 1,
    domain = domain,
    locale = 'zh_CN',
    entries = {
      { context = '', msgid = 'Save', msgstr = '保存' },
      { context = 'menu', msgid = 'Open', msgstr = '打开菜单' },
      { context = 'verb', msgid = 'Open', msgstr = '打开文件' },
      { context = '', msgid = 'Literal 100% [ok] (yes)?', msgstr = '字面量 100% [好]（是）？' },
      { context = '', msgid = 'File {name}: {action}', msgstr = '文件 {name}：{action}' },
      { context = '', msgid = 'Cannot open %s: %s', msgstr = '无法打开 %s：%s' },
      { context = '', msgid = 'Progress %d/%d', msgstr = '进度 %d/%d' },
      { context = '', msgid = 'A', msgstr = 'B' },
      { context = '', msgid = 'B', msgstr = 'C' },
    },
  }
end
check(zh.register_catalog(domain, loader, { upstream = 'test' }), 'catalog registration failed')
zh.setup({ missing = { enabled = true, max_entries = 32 } })

local text, status, id = zh.translate({ domain = domain, msgid = 'Save' })
equal(text, '保存', 'exact translation')
equal(status, 'translated', 'exact status')
check(type(id) == 'string' and id ~= '', 'entry id missing')
equal(zh.translate({ domain = domain, context = 'menu', msgid = 'Open' }), '打开菜单', 'menu context')
equal(zh.translate({ domain = domain, context = 'verb', msgid = 'Open' }), '打开文件', 'verb context')
equal(zh.translate({ domain = domain, context = 'other', msgid = 'Open' }), 'Open', 'context leaked')
equal(zh.translate({ domain = domain, msgid = 'Literal 100% [ok] (yes)?' }), '字面量 100% [好]（是）？', 'pattern escaping')
equal(zh.translate({ domain = domain, msgid = 'Missing' }), 'Missing', 'static fallback')
equal(zh.translate({ domain = 'absent-domain', msgid = 'Missing' }), 'Missing', 'missing catalog fallback')
equal(loads, 1, 'catalog was not lazy-loaded exactly once')

text = zh.translate({ domain = domain, msgid = 'File {name}: {action}', args = { name = '报告.txt', action = '写入' } })
equal(text, '文件 报告.txt：写入', 'named arguments')
text = zh.translate({ domain = domain, msgid = 'File 报告.txt: 写入', formatted = true })
equal(text, '文件 报告.txt：写入', 'formatted named template')
text = zh.translate({ domain = domain, msgid = 'Cannot open /tmp/a b.lua: denied', formatted = true })
equal(text, '无法打开 /tmp/a b.lua：denied', 'printf captures must round-trip verbatim')
text = zh.translate({ domain = domain, msgid = 'Cannot open %s: %s', args = { 'x.lua', 'denied' } })
equal(text, '无法打开 x.lua：denied', 'printf arguments')
text = zh.translate({ domain = domain, msgid = 'Progress %d/%d', args = { 2, 8 } })
equal(text, '进度 2/8', 'numeric printf arguments')
text = zh.translate({ domain = domain, msgid = 'Progress 2/8', formatted = true })
equal(text, '进度 2/8', 'formatted numeric template')
equal(zh.translate({ domain = domain, msgid = 'File {name}: {action}', args = { name = 'x' } }), 'File {name}: {action}', 'missing named argument fallback')
equal(zh.translate({ domain = domain, msgid = 'Cannot open %s: %s', args = { 'x' } }), 'Cannot open %s: %s', 'printf arity fallback')
equal(zh.translate({ domain = domain, msgid = 'Progress two/eight', formatted = true }), 'Progress two/eight', 'unsafe numeric match fallback')
equal(zh.translate({ domain = domain, msgid = 'File x: y: z', formatted = true }), '文件 x：y: z', 'last named capture should retain suffix')

text = zh.translate({ domain = domain, msgid = 'A' })
equal(text, 'B', 'idempotence setup')
equal(zh.translate({ domain = domain, msgid = text }), 'B', 'translated output was translated again')
equal(zh.translate({ domain = domain, msgid = 'A', translated = true }), 'A', 'explicit recursion marker ignored')
print('ENGINE_SPEC=PASS loads=' .. loads)
