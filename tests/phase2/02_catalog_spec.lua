local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then error(message .. ': ' .. tostring(actual), 2) end
end
local zh = require('nvim-zh')
local domain = 'override-fixture'
zh.register_catalog(domain, function()
  return {
    schema = 1,
    domain = domain,
    locale = 'zh_CN',
    entries = {
      { context = '', msgid = 'Save', msgstr = '保存' },
      { context = 'menu', msgid = 'Open', msgstr = '打开' },
      { context = '', msgid = 'File {name}', msgstr = '文件 {name}' },
    },
  }
end)
zh.setup({
  overrides = {
    [domain] = {
      [''] = { Save = '存盘' },
      menu = { Open = '展开', ['File {name}'] = '菜单文件 {name}' },
    },
  },
})
equal(zh.translate({ domain = domain, msgid = 'Save' }), '存盘', 'override did not replace built-in')
equal(zh.translate({ domain = domain, context = 'menu', msgid = 'Open' }), '展开', 'context override failed')
equal(zh.translate({ domain = domain, context = 'menu', msgid = 'File x', formatted = true }), '菜单文件 x', 'template override failed')
equal(zh.translate({ domain = domain, context = 'other', msgid = 'Open' }), 'Open', 'override leaked context')
zh.setup({ overrides = {} })
equal(zh.translate({ domain = domain, msgid = 'Save' }), '保存', 'clearing overrides did not restore built-in')

local invalid = {
  function() end,
  { [domain] = { Save = '保存' } },
  { [domain] = { [''] = { Save = function() return 'x' end } } },
  { [domain] = { [''] = { Save = { msgstr = 'x', loader = function() end } } } },
  { ['bad domain'] = { [''] = { Save = 'x' } } },
}
for index, overrides in ipairs(invalid) do
  check(not pcall(zh.setup, { overrides = overrides }), 'invalid override accepted: ' .. index)
end

zh.register_catalog('broken-fixture', function() error('broken catalog') end)
equal(zh.translate({ domain = 'broken-fixture', msgid = 'Keep' }), 'Keep', 'loader error did not fall back')
zh.register_catalog('invalid-fixture', function() return { schema = 1, domain = 'wrong', entries = {} } end)
equal(zh.translate({ domain = 'invalid-fixture', msgid = 'Keep' }), 'Keep', 'invalid catalog did not fall back')
zh.reload()
equal(zh.translate({ domain = domain, msgid = 'Save' }), '保存', 'reload changed built-in data')
print('CATALOG_SPEC=PASS')
