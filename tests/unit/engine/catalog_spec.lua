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
  modules = { core = { enabled = false } },
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
zh.setup({ modules = { core = { enabled = false } }, overrides = {} })
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

local cat = require('nvim-zh.catalog')
local v2_loads = 0
zh.register_catalog('schema2-fixture', function()
  v2_loads = v2_loads + 1
  return {
    schema = 2,
    domain = 'schema2-fixture',
    locale = 'zh_CN',
    entries = {
      [''] = { Save = '保存V2', ['Item {name}'] = '条目 {name}' },
      menu = { Open = '打开V2' },
    },
  }
end)
equal(zh.translate({ domain = 'schema2-fixture', msgid = 'Save' }), '保存V2', 'schema 2 exact')
equal(zh.translate({ domain = 'schema2-fixture', context = 'menu', msgid = 'Open' }), '打开V2', 'schema 2 context')
equal(zh.translate({ domain = 'schema2-fixture', msgid = 'Item foo', formatted = true }), '条目 foo', 'schema 2 template')
cat.configure({ overrides = {
  ['schema2-fixture'] = { [''] = { Save = '覆盖保存', ['Item {name}'] = '覆盖条目 {name}' } },
} })
equal(zh.translate({ domain = 'schema2-fixture', msgid = 'Save' }), '覆盖保存', 'schema 2 override')
equal(zh.translate({ domain = 'schema2-fixture', msgid = 'Item foo', formatted = true }), '覆盖条目 foo', 'schema 2 template override')
equal(v2_loads, 1, 'override overlay should not reload base catalog')
cat.configure({ overrides = {} })
equal(zh.translate({ domain = 'schema2-fixture', msgid = 'Save' }), '保存V2', 'schema 2 override cleared')
equal(v2_loads, 1, 'clearing override overlay should not reload base catalog')
dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
equal(zh.translate({ domain = domain, msgid = 'Save' }), '保存', 'reload changed built-in data')
print('CATALOG_SPEC=PASS')
