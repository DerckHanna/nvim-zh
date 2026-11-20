local M = {}

local defaults = {
  modules = {
    core = { enabled = true, apply_language = true },
    help = { enabled = true, lang = { 'cn', 'en' } },
    ui = { notify = true, prompts = true, select_items = false, echo = false },
    plugins = { auto = true, lazy_load = true, disabled = {} },
    diagnostics = { enabled = true, virtual_text = true, virtual_lines = true, float = true, lists = true },
    lsp = { messages = true, progress = true, hints = true },
  },
  overrides = {},
  pack_sources = {},
  missing = { enabled = true, max_entries = 2000 },
}

local function expect(value, expected, name)
  if type(value) ~= expected then
    error(('nvim-zh: %s must be %s'):format(name, expected), 3)
  end
end

function M.resolve(opts)
  if opts == nil then opts = {} end
  expect(opts, 'table', 'setup options')
  local config = M.merge(defaults, opts)
  expect(config.modules.core.enabled, 'boolean', 'modules.core.enabled')
  expect(config.modules.core.apply_language, 'boolean', 'modules.core.apply_language')
  expect(config.modules.plugins, 'table', 'modules.plugins')
  expect(config.modules.plugins.auto, 'boolean', 'modules.plugins.auto')
  expect(config.modules.plugins.lazy_load, 'boolean', 'modules.plugins.lazy_load')
  expect(config.modules.plugins.disabled, 'table', 'modules.plugins.disabled')
  for index, name in ipairs(config.modules.plugins.disabled) do
    expect(name, 'string', ('modules.plugins.disabled[%d]'):format(index))
  end
  expect(config.modules.diagnostics, 'table', 'modules.diagnostics')
  for _, name in ipairs({ 'enabled', 'virtual_text', 'virtual_lines', 'float', 'lists' }) do
    expect(config.modules.diagnostics[name], 'boolean', 'modules.diagnostics.' .. name)
  end
  expect(config.modules.lsp, 'table', 'modules.lsp')
  expect(config.modules.lsp.messages, 'boolean', 'modules.lsp.messages')
  expect(config.modules.lsp.progress, 'boolean', 'modules.lsp.progress')
  expect(config.modules.lsp.hints, 'boolean', 'modules.lsp.hints')
  expect(config.modules.ui, 'table', 'modules.ui')
  expect(config.modules.ui.notify, 'boolean', 'modules.ui.notify')
  expect(config.modules.ui.prompts, 'boolean', 'modules.ui.prompts')
  expect(config.modules.ui.select_items, 'boolean', 'modules.ui.select_items')
  expect(config.modules.ui.echo, 'boolean', 'modules.ui.echo')
  expect(config.modules.help.enabled, 'boolean', 'modules.help.enabled')
  expect(config.modules.help.lang, 'table', 'modules.help.lang')
  for index, lang in ipairs(config.modules.help.lang) do
    expect(lang, 'string', ('modules.help.lang[%d]'):format(index))
  end
  expect(config.missing, 'table', 'missing')
  expect(config.missing.enabled, 'boolean', 'missing.enabled')
  expect(config.missing.max_entries, 'number', 'missing.max_entries')
  if config.missing.max_entries < 1 or config.missing.max_entries % 1 ~= 0 then
    error('nvim-zh: missing.max_entries must be a positive integer', 2)
  end
  expect(config.overrides, 'table', 'overrides')
  local store = require('nvim-zh.pack_store')
  for id, source in pairs(config.pack_sources) do
    assert(store.id(id) and id ~= 'official' and id ~= 'local' and type(source) == 'table'
      and store.https(source.url) and (source.allow_lua == nil or type(source.allow_lua) == 'boolean'), '无效的汉化包发布源')
    for key in pairs(source) do assert(key == 'url' or key == 'allow_lua', '未知的汉化包发布源字段') end
  end
  require('nvim-zh.catalog').validate_overrides(config.overrides)
  return config
end

function M.merge(base, layer, prefix)
  local result = vim.deepcopy(base)
  for key, value in pairs(layer) do
    local name = (prefix and prefix .. '.' or '') .. tostring(key)
    assert(base[key] ~= nil, 'nvim-zh: unknown option ' .. name)
    if name == 'pack_sources' then
      expect(value, 'table', name)
      result[key] = vim.deepcopy(value)
    elseif name == 'overrides' then
      expect(value, 'table', name)
      result[key] = vim.tbl_deep_extend('force', result[key], value)
    elseif name == 'modules.plugins.disabled' or name == 'modules.help.lang' then
      assert(type(value) == 'table' and vim.islist(value) and #value <= 256, name .. ' must be an array')
      result[key] = vim.deepcopy(value)
    elseif type(base[key]) == 'table' then
      assert(type(value) == 'table', name .. ' must be table')
      result[key] = M.merge(base[key], value, name)
    else
      assert(type(value) == type(base[key]), name .. ' has invalid type')
      result[key] = value
    end
  end
  return result
end

return M
