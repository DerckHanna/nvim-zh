local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local failures = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end

local function setup(opts)
  local base = {
    modules = {
      core = { enabled = false }, help = { enabled = false },
      ui = { notify = false, prompts = false, echo = false }, plugins = { auto = false },
      diagnostics = { enabled = false }, lsp = { messages = false, progress = false },
    },
    missing = { enabled = true, max_entries = 16 },
  }
  require('nvim-zh').setup(vim.tbl_deep_extend('force', base, opts or {}))
end

local methods = { 'window/showMessage', 'window/showMessageRequest', '$/progress' }
local function save_handlers()
  local saved = {}
  for _, method in ipairs(methods) do saved[method] = vim.lsp.handlers[method] end
  return saved
end
local function restore_handlers(saved)
  for method, handler in pairs(saved) do vim.lsp.handlers[method] = handler end
end
local function health_map()
  local result = {}
  for _, item in ipairs(require('nvim-zh.health').collect()) do result[item.name] = item.status end
  return result
end

test('lsp_handler_config_is_forwarded', function()
  local zh = require('nvim-zh')
  local saved = save_handlers()
  local old_get = vim.lsp.get_client_by_id
  local received = {}
  vim.lsp.handlers['window/showMessage'] = function(_, params, _, handler_config)
    if params == nil then
      received.fallback = handler_config
    else
      received['window/showMessage'] = handler_config
    end
    return 'show'
  end
  vim.lsp.handlers['window/showMessageRequest'] = function(_, _, _, handler_config)
    received['window/showMessageRequest'] = handler_config
    return 'request'
  end
  vim.lsp.handlers['$/progress'] = function(_, _, _, handler_config)
    received['$/progress'] = handler_config
    return 'progress'
  end
  vim.lsp.get_client_by_id = function(id) return { id = id, name = 'clangd' } end
  setup({ modules = { lsp = { messages = true, progress = true } } })
  local marker = { source = 'handler-config' }
  local fallback_marker = { source = 'fallback-config' }
  local ctx = { client_id = 71 }
  vim.lsp.handlers['window/showMessage'](nil, { message = 'Untranslated' }, ctx, marker)
  vim.lsp.handlers['window/showMessageRequest'](nil, { message = 'Untranslated', actions = {} }, ctx, marker)
  vim.lsp.handlers['$/progress'](nil, { value = { title = 'Untranslated' } }, ctx, marker)
  vim.lsp.handlers['window/showMessage'](nil, nil, ctx, fallback_marker)
  setup()
  restore_handlers(saved)
  vim.lsp.get_client_by_id = old_get
  for _, method in ipairs(methods) do check(received[method] == marker, method .. ' dropped handler config') end
  check(received.fallback == fallback_marker, 'showMessage fallback dropped handler config')
end)

test('diagnostic_context_probes_observe_once', function()
  local message = "Unknown type name 'runtime_fixture'"
  vim.diagnostic.config({
    virtual_text = { format = function(diagnostic) return diagnostic.message end },
    virtual_lines = false,
    float = false,
  })
  setup({
    modules = { diagnostics = { enabled = true, virtual_text = true, virtual_lines = false, float = false } },
    overrides = { clangd = { unknown_type_name = { [message] = '未知类型名' } } },
  })
  local missing = require('nvim-zh.missing')
  missing.reset()
  local formatter = vim.diagnostic.config().virtual_text.format
  local translated = formatter({ message = message, source = 'clangd' })
  local known_stats = require('nvim-zh').stats()
  missing.reset()
  local unknown = formatter({ message = 'unmatched runtime diagnostic', source = 'clangd' })
  local unknown_stats = require('nvim-zh').stats()
  setup()
  equal(translated, '未知类型名', 'diagnostic context fixture did not translate')
  equal(known_stats.runtime.observed, 1, 'one diagnostic was observed once per probed context')
  equal(known_stats.missing.unique, 0, 'successful later-context lookup left false missing entries')
  equal(unknown, 'unmatched runtime diagnostic', 'unknown diagnostic fallback')
  equal(unknown_stats.runtime.observed, 1, 'unknown diagnostic was observed once per probed context')
  equal(unknown_stats.missing.occurrences, 1, 'unknown diagnostic missing occurrence count')
  equal(unknown_stats.missing.unique, 1, 'unknown diagnostic missing unique count')
end)

test('diagnostic_restore_preserves_external_options', function()
  local user_format = function(diagnostic) return diagnostic.message end
  vim.diagnostic.config({
    virtual_text = { format = user_format, prefix = 'before', spacing = 1 },
    virtual_lines = false,
    float = false,
  })
  setup({ modules = { diagnostics = { enabled = true, virtual_text = true, virtual_lines = false, float = false } } })
  local ours = vim.diagnostic.config().virtual_text.format
  vim.diagnostic.config({ virtual_text = { format = ours, prefix = 'external', spacing = 7 } })
  setup()
  local restored = vim.diagnostic.config().virtual_text
  check(type(restored) == 'table', 'restored virtual_text is not a table')
  equal(restored.format, user_format, 'original formatter was not restored')
  equal(restored.prefix, 'external', 'external prefix was rolled back')
  equal(restored.spacing, 7, 'external spacing was rolled back')
end)

test('health_honors_explicitly_disabled_diagnostics', function()
  vim.diagnostic.config({ virtual_text = false, virtual_lines = false, float = false })
  setup({ modules = { diagnostics = {
    enabled = true, virtual_text = false, virtual_lines = false, float = false,
  } } })
  local statuses = health_map()
  for _, name in ipairs({ 'virtual_text', 'virtual_lines', 'float' }) do
    equal(statuses['diagnostics.' .. name], 'info', 'explicitly disabled diagnostic health status')
  end
end)

test('health_reports_progress_only_lsp', function()
  local saved = save_handlers()
  vim.lsp.handlers['$/progress'] = function() return 'progress' end
  setup({ modules = { lsp = { messages = false, progress = true } } })
  local status = health_map()['lsp.clangd']
  setup()
  restore_handlers(saved)
  equal(status, 'ok', 'active progress-only LSP adapter was not healthy')
end)

test('health_reports_lsp_external_override', function()
  local saved = save_handlers()
  vim.lsp.handlers['window/showMessage'] = function() return 'show' end
  vim.lsp.handlers['window/showMessageRequest'] = function() return 'request' end
  setup({ modules = { lsp = { messages = true, progress = false } } })
  vim.lsp.handlers['window/showMessage'] = function() return 'external' end
  dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
  local status = health_map()['lsp.clangd']
  setup()
  restore_handlers(saved)
  equal(status, 'warn', 'degraded LSP handler chain was reported healthy')
end)

test('health_show_returns_unique_entries', function()
  setup()
  local old_notify = vim.notify
  vim.notify = function() end
  local results = require('nvim-zh.health').show()
  vim.notify = old_notify
  local seen, duplicates = {}, {}
  for _, item in ipairs(results) do
    if seen[item.name] then table.insert(duplicates, item.name) end
    seen[item.name] = true
  end
  equal(#duplicates, 0, 'health.show duplicate entries: ' .. table.concat(duplicates, ','))
end)

if #failures > 0 then
  for _, failure in ipairs(failures) do print('RUNTIME_REGRESSION_FAILURE=' .. failure) end
  error(table.concat(failures, '\n'), 0)
end
print('DIAGNOSTIC_RUNTIME_REGRESSION_SPEC=PASS lsp_config=true diagnostics=true health=true')
