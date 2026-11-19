local zh = require('nvim-zh')
local allowed = { setup=true, status=true, translate=true, register_catalog=true, stats=true,
  missing=true, open=true, check=true, refresh=true, teardown=true,
  register_adapter_source=true, register_adapter=true }
for name, fn in pairs(zh) do
  assert(allowed[name] and type(fn) == 'function', 'unexpected public API: ' .. name)
  allowed[name] = nil
end
assert(next(allowed) == nil, 'public API incomplete')
local before = zh.status()
assert(not before.configured)
assert(next(zh.missing()) == nil and zh.stats().runtime.observed == 0)
assert(not zh.status().configured and zh.status().version.active_bundle == nil, 'query performed setup')
local generation = 1
zh.register_catalog('command-fixture', function()
  return { schema=1, domain='command-fixture', locale='zh_CN', entries={
    { msgid='Save', msgstr=generation == 1 and '保存' or '存盘' },
  } }
end)
zh.setup({ modules={core={enabled=false}} })
assert(zh.translate({domain='command-fixture',msgid='Save'}) == '保存')
zh.translate({domain='command-fixture',msgid='Unknown command message'})
assert(zh.missing()[1].msgid == 'Unknown command message', 'missing query lost source')
generation = 2
dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
assert(zh.translate({domain='command-fixture',msgid='Save'}) == '存盘', 'refresh retained loader data')
for _, command in ipairs({'NvimZhMissing','NvimZhInfo','NvimZhReload','NvimZhUpdate','NvimZhRollback'}) do
  assert(vim.fn.exists(':' .. command) == 0, 'retired command exists')
end
print('PUBLIC_CATALOG_QUERIES=PASS facade query_no_setup missing refresh')
