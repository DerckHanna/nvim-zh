local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local overrides = h.overrides()
overrides.telescope = { title = {
  ['Find Files'] = '查找文件',
  ['Find Word (%s)'] = '查找单词 (%s)',
  ['File Preview'] = '文件预览',
  Help = '帮助',
  Prompt = '提示',
  Results = '结果',
} }
local function use_source_catalogs()
  -- Dynamic-title specs must not depend on a separately built resource bundle.
  require('nvim-zh.catalog').use_sources(h.empty_catalogs())
end
local function setup(plugins)
  h.setup(plugins, overrides)
  use_source_catalogs()
end
local function refresh()
  local id = require('nvim-zh').refresh()
  use_source_catalogs()
  return id
end

local calls = {}
local throw_original = false
local previewer = { static_title = 'Help' }
local original_title = function(self, entry, dynamic)
  calls[#calls + 1] = { self = self, entry = entry, dynamic = dynamic }
  if throw_original then error('original-previewer-error') end
  local title
  if dynamic then
    title = entry and entry.dynamic_title
  else
    title = self.static_title
  end
  return title, 'title-return'
end
previewer.title = original_title
package.loaded['telescope.previewers.previewer'] = previewer
package.loaded['telescope.pickers.window'] = {
  get_initial_window_options = function(picker)
    return {
      prompt = { title = picker.prompt_title },
      results = { title = picker.results_title },
      preview = { title = picker.preview_title },
    }
  end,
}
package.loaded['telescope.pickers'] = { new = function(opts) return opts end }
package.loaded['telescope.utils'] = nil

setup()
equal(package.loaded['telescope.utils'], nil, 'adapter forced telescope.utils to load')
local entry = { dynamic_title = 'Find Files', payload = { unchanged = true } }
local returns = pack(previewer:title(entry, false))
equal(returns.n, 2, 'Previewer title return arity')
equal(returns[1], '帮助', 'static previewer title')
equal(returns[2], 'title-return', 'Previewer trailing return value')
equal(previewer:title(entry, true), '查找文件', 'dynamic previewer title')
entry.dynamic_title = 'Find Word (needle)'
equal(previewer:title(entry, true), '查找单词 (needle)', 'dynamic formatted title')
entry.dynamic_title = '/tmp/动态路径.lua'
equal(previewer:title(entry, true), '/tmp/动态路径.lua', 'dynamic path fallback')
entry.dynamic_title = 'Unknown title'
equal(previewer:title(entry, true), 'Unknown title', 'unknown dynamic title fallback')
entry.dynamic_title = false
equal(previewer:title(entry, true), false, 'false dynamic title changed')
entry.dynamic_title = nil
equal(previewer:title(entry, true), nil, 'nil dynamic title changed')
previewer.static_title = ''
equal(previewer:title(entry, false), '', 'empty static title changed')
check(calls[1].entry == entry and calls[1].self == previewer and calls[1].dynamic == false,
  'Previewer self/entry/arguments changed')

local wrapped = previewer.title
check(wrapped ~= original_title, 'Previewer wrapper missing')
setup()
refresh()
equal(previewer.title, wrapped, 'setup/refresh replaced the owned Previewer wrapper')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('previewer translation error') end
entry.dynamic_title = 'Find Files'
equal(previewer:title(entry, true), 'Find Files', 'Previewer translation exception fallback')
engine.translate = original_translate

throw_original = true
local ok, err = pcall(previewer.title, previewer, entry, true)
throw_original = false
check(not ok and tostring(err):find('original-previewer-error', 1, true),
  'original Previewer exception swallowed')

setup({ auto = true, disabled = { 'telescope' } })
equal(previewer.title, original_title, 'Telescope disable did not restore Previewer.title')
entry.dynamic_title = 'Find Files'
equal(wrapped(previewer, entry, true), 'Find Files', 'retained stale Previewer wrapper stayed active')

setup()
check(previewer.title ~= original_title, 'Previewer reattach failed')
local old_previewer = previewer
local old_wrapper = previewer.title
previewer = { title = original_title, static_title = 'File Preview' }
package.loaded['telescope.previewers.previewer'] = previewer
refresh()
equal(old_previewer.title, original_title, 'old Previewer generation was not restored')
check(previewer.title ~= original_title, 'new Previewer generation was not attached')
equal(old_wrapper(old_previewer, entry, true), 'Find Files', 'old Previewer generation stayed active')
equal(previewer:title(entry, false), '文件预览', 'new Previewer static title')

local external = function()
  return 'External Title'
end
previewer.title = external
refresh()
equal(previewer.title, external, 'refresh reclaimed external Previewer.title')
equal(require('nvim-zh').status().plugins.telescope.previewer.reason, 'external_override',
  'external Previewer override not reported')
require('nvim-zh.plugins').teardown()
equal(previewer.title, external, 'teardown reclaimed external Previewer.title')
print('TELESCOPE_DYNAMIC_SPEC=PASS static,dynamic placeholders,path_fallback false_nil,generations,external_override')
