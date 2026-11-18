local failures = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end
local zh = require('nvim-zh')
local function setup(max_entries)
  zh.setup({
    modules = {
      core = { enabled = false }, help = { enabled = false },
      ui = { notify = false, prompts = false, echo = false }, plugins = { auto = false },
      diagnostics = { enabled = false }, lsp = { messages = false, progress = false },
    },
    missing = { enabled = true, max_entries = max_entries or 8 },
  })
end

test('late_registration_invalidates_negative_cache', function()
  setup()
  local domain = 'late-register-fixture'
  equal(zh.translate({ domain = domain, msgid = 'Save' }), 'Save', 'unregistered domain fallback')
  zh.register_catalog(domain, function()
    return { schema = 1, domain = domain, locale = 'zh_CN', entries = {
      { context = '', msgid = 'Save', msgstr = '保存' },
    } }
  end)
  equal(zh.translate({ domain = domain, msgid = 'Save' }), '保存', 'late registration remained negatively cached')
end)

test('translated_hits_are_bounded', function()
  local domain = 'bounded-hits-fixture'
  zh.register_catalog(domain, function()
    return { schema = 1, domain = domain, locale = 'zh_CN', entries = {
      { context = '', msgid = 'Known {name}', msgstr = '已知 {name}' },
    } }
  end)
  setup(2)
  require('nvim-zh.missing').reset()
  for index = 1, 5 do
    equal(zh.translate({ domain = domain, msgid = 'Known ' .. index, formatted = true }), '已知 ' .. index,
      'dynamic translation fixture')
  end
  local stats = zh.stats()
  equal(stats.runtime.translated, 5, 'translated occurrence total')
  check(stats.runtime.translated_unique <= 2,
    'translated hit cache exceeded max_entries: ' .. tostring(stats.runtime.translated_unique))
  check(stats.runtime.truncated, 'translated hit eviction was not reported as truncated')
  setup(1)
  check(zh.stats().runtime.translated_unique <= 1, 'lowering max_entries did not shrink translated hits')
end)

if #failures > 0 then
  for _, failure in ipairs(failures) do print('RUNTIME_REGRESSION_FAILURE=' .. failure) end
  error(table.concat(failures, '\n'), 0)
end
print('ENGINE_RUNTIME_REGRESSION_SPEC=PASS late_registration=true hits_bounded=true')
