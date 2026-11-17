local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local calls = {}
local throw_original = false
local pickers = {}
local original_new = function(opts, defaults)
  table.insert(calls, { opts = opts, defaults = defaults })
  if throw_original then error('original-telescope-error') end
  local result = {}
  for key, value in pairs(defaults or {}) do result[key] = value end
  for key, value in pairs(opts or {}) do result[key] = value end
  return result, 'picker-return'
end
pickers.new = original_new
package.loaded['telescope.pickers'] = pickers

h.setup()
check(pickers.new ~= original_new, 'Telescope pickers.new was not wrapped')
local info = require('nvim-zh').info().plugins.telescope
check(info.active and info.seam == 'pickers.new', 'Telescope active capability missing')
local wrapper = pickers.new
h.setup()
check(pickers.new == wrapper, 'repeated setup stacked Telescope wrapper')

local finder = { original = true }
local entry_maker = function(value) return { value = value } end
local attach_mappings = function() return true end
local opts = {
  prompt_title = 'Find Files', results_title = false,
  finder = finder, entry_maker = entry_maker, attach_mappings = attach_mappings,
}
local defaults = {
  prompt_title = 'Help Tags', results_title = 'Help Tags', preview_title = 'Git Commits',
  finder = function() error('default finder must not replace explicit finder') end,
}
local returns = pack(pickers.new(opts, defaults))
equal(returns.n, 2, 'Telescope return arity')
equal(returns[2], 'picker-return', 'Telescope second return')
local picker = returns[1]
equal(picker.prompt_title, '查找文件', 'prompt title')
equal(picker.results_title, false, 'false results title changed')
equal(picker.preview_title, 'Git 提交', 'default preview title')
check(picker.finder == finder and picker.entry_maker == entry_maker, 'finder/entry_maker identity changed')
check(picker.attach_mappings == attach_mappings, 'attach_mappings identity changed')
equal(opts.prompt_title, 'Find Files', 'caller opts mutated')
equal(defaults.prompt_title, 'Help Tags', 'caller defaults mutated')
check(calls[#calls].opts ~= opts and calls[#calls].defaults ~= defaults, 'Telescope inputs modified in place')
check(calls[#calls].opts.results_title == false, 'false title not preserved at wrapper boundary')

local unknown_picker = pickers.new({ prompt_title = '未知标题', results_title = 'Help Tags' }, {})
equal(unknown_picker.prompt_title, '未知标题', 'unknown title fallback')
equal(unknown_picker.results_title, '帮助标签', 'opts results title')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('telescope translation error') end
local fallback = pickers.new({ prompt_title = 'Find Files' }, {})
equal(fallback.prompt_title, 'Find Files', 'translation exception fallback')
engine.translate = original_translate

throw_original = true
local ok, err = pcall(pickers.new, { prompt_title = 'Find Files' }, {})
throw_original = false
check(not ok and tostring(err):find('original-telescope-error', 1, true), 'original Telescope exception swallowed')

require('nvim-zh').reload()
equal(pickers.new({ prompt_title = 'Find Files' }, {}).prompt_title, '查找文件', 'reload translation')
h.setup({ auto = true, disabled = { 'telescope' } })
check(pickers.new == original_new, 'disabling Telescope did not restore original')
equal(pickers.new({ prompt_title = 'Find Files' }, {}).prompt_title, 'Find Files', 'disabled Telescope translated')
print('TELESCOPE_ADAPTER_SPEC=PASS seam=pickers.new entries=unchanged')
