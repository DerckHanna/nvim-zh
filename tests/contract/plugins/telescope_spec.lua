local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local overrides = h.overrides()
overrides.telescope = { title = {
  ['Find Files'] = '查找文件',
  ['Find Word (%s)'] = '查找单词 (%s)',
  ['File Preview'] = '文件预览',
  ['Grep Preview'] = 'Grep 预览',
  Help = '帮助',
  Prompt = '提示',
  Results = '结果',
} }
local function use_source_catalogs()
  -- Adapter specs must not depend on a separately built resource bundle.
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
local function status()
  return require('nvim-zh').status().plugins.telescope
end

local module_names = {
  'telescope.pickers.window',
  'telescope.previewers.previewer',
  'telescope.pickers',
}
local preload_calls = 0
for _, name in ipairs(module_names) do
  package.loaded[name] = nil
  package.preload[name] = function()
    preload_calls = preload_calls + 1
    error('forced Telescope load: ' .. name)
  end
end
setup()
equal(preload_calls, 0, 'absent Telescope modules were forced to load')
equal(status().reason, 'not_loaded', 'absent Telescope status')
equal(status().refine_change_title, 'uncovered_no_safe_seam', 'refine limitation not reported')
check(status().uncovered:find('change_title', 1, true) ~= nil, 'refine change_title boundary missing')
for _, name in ipairs(module_names) do package.preload[name] = nil end

local picker_calls = {}
local throw_original = false
local sync_expected = false
local window, previewer
local last_window_options
local original_window, original_title
local original_new = function(...)
  local args = pack(...)
  if sync_expected then
    check(window.get_initial_window_options ~= original_window, 'window wrapper installed too late')
    check(previewer.title ~= original_title, 'Previewer wrapper installed too late')
  end
  picker_calls[#picker_calls + 1] = args
  if throw_original then error('original-telescope-error') end
  local opts, defaults = args[1] or {}, args[2] or {}
  local picker = {}
  for key, value in pairs(defaults) do picker[key] = value end
  for key, value in pairs(opts) do picker[key] = value end
  return picker, nil, 'picker-return'
end
local pickers = { new = original_new }
package.loaded['telescope.pickers'] = pickers
setup()
check(pickers.new ~= original_new, 'Telescope lifecycle hook was not installed')
equal(status().reason, 'lifecycle_only', 'lifecycle-only capability was misreported')
local lifecycle_wrapper = pickers.new
setup()
equal(pickers.new, lifecycle_wrapper, 'repeated setup stacked pickers.new')

window = {}
original_window = function(picker, extra)
  local options = {
    prompt = { title = picker.prompt_title, border = 'prompt-border', enter = true },
    results = { title = picker.results_title, border = 'results-border', enter = false },
    preview = { title = picker.preview_title, border = 'preview-border', enter = false },
    extra = extra,
  }
  last_window_options = options
  return options, 'window-return'
end
window.get_initial_window_options = original_window
package.loaded['telescope.pickers.window'] = window

previewer = { static_title = 'File Preview' }
original_title = function(self, entry, dynamic)
  if dynamic then return entry and entry.dynamic_title end
  return self.static_title
end
previewer.title = original_title
package.loaded['telescope.previewers.previewer'] = previewer
sync_expected = true

local finder = { original = true }
local entry_maker = function(value) return { value = value } end
local attach_mappings = function() return true end
local opts = {
  prompt_title = 'Find Files',
  results_title = false,
  preview_title = 'File Preview',
  finder = finder,
  attach_mappings = attach_mappings,
}
local defaults = {
  prompt_title = 'Help',
  results_title = 'Results',
  preview_title = 'Grep Preview',
  entry_maker = entry_maker,
}
local opts_snapshot, defaults_snapshot = vim.deepcopy(opts), vim.deepcopy(defaults)
local returns = pack(pickers.new(opts, defaults, 'third-argument'))
equal(returns.n, 3, 'Telescope return arity')
equal(returns[1].prompt_title, 'Find Files', 'picker prompt behavior value changed')
equal(returns[1].results_title, false, 'picker results behavior value changed')
equal(returns[1].preview_title, 'File Preview', 'picker preview behavior value changed')
equal(returns[3], 'picker-return', 'Telescope trailing return value')
equal(picker_calls[#picker_calls].n, 3, 'Telescope argument arity')
check(picker_calls[#picker_calls][1] == opts and picker_calls[#picker_calls][2] == defaults,
  'pickers.new replaced caller arguments')
equal(picker_calls[#picker_calls][3], 'third-argument', 'pickers.new trailing argument')
check(vim.deep_equal(opts, opts_snapshot) and vim.deep_equal(defaults, defaults_snapshot),
  'pickers.new mutated opts/defaults')
local picker = returns[1]
check(picker.finder == finder and picker.entry_maker == entry_maker
  and picker.attach_mappings == attach_mappings, 'picker behavior callbacks changed')

local window_returns = pack(window.get_initial_window_options(picker, 'resize-options'))
equal(window_returns.n, 2, 'window return arity')
equal(window_returns[2], 'window-return', 'window trailing return')
local options = window_returns[1]
equal(options.prompt.title, '查找文件', 'prompt display projection')
equal(options.results.title, false, 'false results title changed')
equal(options.preview.title, '文件预览', 'preview display projection')
equal(options.extra, 'resize-options', 'window options payload changed')
check(options.prompt.border == 'prompt-border' and options.results.enter == false,
  'non-title window options changed')
equal(picker.prompt_title, 'Find Files', 'window projection rewrote prompt_title')
equal(picker.results_title, false, 'window projection rewrote results_title')
equal(picker.preview_title, 'File Preview', 'window projection rewrote preview_title')

local default_picker = pickers.new({ finder = finder }, {
  prompt_title = 'Prompt', results_title = 'Results', preview_title = 'File Preview',
})
local default_options = window.get_initial_window_options(default_picker)
equal(default_options.prompt.title, '提示', 'default Prompt title')
equal(default_options.results.title, '结果', 'default Results title')
equal(default_options.preview.title, '文件预览', 'default File Preview title')
equal(default_picker.prompt_title, 'Prompt', 'default internal prompt title')
equal(default_picker.results_title, 'Results', 'default internal results title')
equal(default_picker.preview_title, 'File Preview', 'default internal preview title')

picker.prompt_title = 'Find Word (needle)'
picker.results_title = 'Unknown title'
picker.preview_title = '/tmp/未翻译.lua'
local dynamic_options = window.get_initial_window_options(picker)
equal(dynamic_options.prompt.title, '查找单词 (needle)', 'formatted title placeholder')
equal(dynamic_options.results.title, 'Unknown title', 'unknown title fallback')
equal(dynamic_options.preview.title, '/tmp/未翻译.lua', 'dynamic path fallback')

local projected = window.get_initial_window_options(default_picker)
check(last_window_options ~= projected and last_window_options.prompt ~= projected.prompt,
  'display projection aliased original options')
equal(last_window_options.prompt.title, 'Prompt', 'original returned options mutated')

local owned_window = window.get_initial_window_options
local owned_previewer = previewer.title
setup()
refresh()
check(window.get_initial_window_options == owned_window and previewer.title == owned_previewer,
  'setup/refresh stacked display wrappers')
check(pickers.new == lifecycle_wrapper, 'setup/refresh replaced lifecycle wrapper')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('telescope translation error') end
local fallback = window.get_initial_window_options(default_picker)
equal(fallback.prompt.title, 'Prompt', 'translation exception fallback')
engine.translate = original_translate

throw_original = true
local ok, err = pcall(pickers.new, opts, defaults)
throw_original = false
check(not ok and tostring(err):find('original-telescope-error', 1, true),
  'original Telescope exception swallowed')

setup({ auto = true, disabled = { 'telescope' } })
check(pickers.new == original_new and window.get_initial_window_options == original_window
  and previewer.title == original_title, 'disabling Telescope did not restore originals')
equal(owned_window(default_picker).prompt.title, 'Prompt', 'retained stale window wrapper stayed active')
equal(window.get_initial_window_options(default_picker).prompt.title, 'Prompt',
  'disabled Telescope translated a title')

setup()
check(pickers.new ~= original_new and window.get_initial_window_options ~= original_window
  and previewer.title ~= original_title, 're-enabling Telescope did not reattach')
local old_window = window
local old_pickers = pickers
local old_previewer = previewer
local old_window_wrapper = window.get_initial_window_options
local adapter = require('nvim-zh.adapters.telescope')
local old_signature = adapter.signature()

window = { get_initial_window_options = original_window }
previewer = { title = original_title, static_title = 'File Preview' }
pickers = { new = original_new }
package.loaded['telescope.pickers.window'] = window
package.loaded['telescope.previewers.previewer'] = previewer
package.loaded['telescope.pickers'] = pickers
refresh()
check(old_window.get_initial_window_options == original_window
  and old_pickers.new == original_new and old_previewer.title == original_title,
  'old module generations were not restored')
check(window.get_initial_window_options ~= original_window and pickers.new ~= original_new
  and previewer.title ~= original_title, 'new module generations were not attached')
equal(old_window_wrapper(default_picker).prompt.title, 'Prompt', 'old generation wrapper stayed active')
equal(window.get_initial_window_options(default_picker).prompt.title, '提示',
  'new generation window projection')
check(adapter.signature() ~= old_signature, 'module generation did not change signature')

local external_window = function(...)
  return original_window(...)
end
window.get_initial_window_options = external_window
refresh()
equal(window.get_initial_window_options, external_window, 'refresh reclaimed external window override')
equal(status().window.reason, 'external_override', 'external window override not reported')
require('nvim-zh.plugins').teardown()
equal(window.get_initial_window_options, external_window, 'teardown overwrote external window override')
check(pickers.new == original_new and previewer.title == original_title,
  'teardown did not restore owned new-generation wrappers')
print('TELESCOPE_ADAPTER_SPEC=PASS seam=window_projection internal_titles=unchanged lifecycle=safe generations=true')
