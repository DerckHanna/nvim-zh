local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local telescope_root = vim.env.NVIM_ZH_TEST_TELESCOPE
local plenary_root = vim.env.NVIM_ZH_TEST_PLENARY
assert(telescope_root and plenary_root, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(plenary_root)
vim.opt.runtimepath:prepend(telescope_root)

local overrides = h.overrides()
overrides.telescope = {
  title = {
    ['Find Files'] = '查找文件',
    ['Find Word (%s)'] = '查找单词 (%s)',
    ['File Preview'] = '文件预览',
    ['Grep Preview'] = 'Grep 预览',
    ['Help Preview'] = '帮助预览',
    ['LSP Dynamic Workspace Symbols'] = 'LSP 动态工作区符号',
    ['LSP Workspace Symbols'] = 'LSP 工作区符号',
    Help = '帮助',
    ['Live Grep'] = '实时 Grep',
    Prompt = '提示',
    Results = '结果',
  },
  notification = {
    ['[telescope.%s]: You need to install either find, fd, or rg'] =
      '[telescope.%s]: 你需要安装 find、fd 或 rg 中的任意一个',
  },
}
local notifications = {}
local once_calls = 0
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = { message = message, level = level, opts = opts }
end
vim.notify_once = function(message, level, opts)
  once_calls = once_calls + 1
  return vim.notify(message, level, opts)
end

require('telescope').setup({})
local pickers = require('telescope.pickers')
local window = require('telescope.pickers.window')
local Previewer = require('telescope.previewers.previewer')
local utils = require('telescope.utils')
local finders = require('telescope.finders')
local builtin = require('telescope.builtin')
local original_new = pickers.new
local original_window = window.get_initial_window_options
local original_title = Previewer.title
local original_notify = utils.notify

require('nvim-zh').setup({
  modules = {
    core = { enabled = false },
    ui = { notify = true, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
  overrides = overrides,
  missing = { enabled = true, max_entries = 64 },
})
-- Keep this upstream contract independent from a separately built resource bundle.
require('nvim-zh.catalog').use_sources(h.empty_catalogs())
check(pickers.new ~= original_new, 'real Telescope lifecycle hook not attached')
check(window.get_initial_window_options ~= original_window, 'real Telescope window seam not attached')
check(Previewer.title ~= original_title, 'real Telescope Previewer seam not attached')
equal(utils.notify, original_notify, 'adapter wrapped telescope.utils.notify')

local captured
local original_find = pickers._Picker.find
pickers._Picker.find = function(self)
  captured = self
  return self
end
local function construct(name, opts)
  captured = nil
  builtin[name](opts or {})
  check(captured ~= nil, 'real builtin did not construct picker: ' .. name)
  return captured
end

local help_picker = construct('help_tags')
equal(help_picker.prompt_title, 'Help', 'real Help internal prompt title')
equal(help_picker.results_title, 'Results', 'real Help internal results title')
local help_options = window.get_initial_window_options(help_picker)
equal(help_options.prompt.title, '帮助', 'real Help display title')
equal(help_options.results.title, '结果', 'real Help default Results title')
equal(help_options.preview.title, '帮助预览', 'real Help preview title')

local files_picker = construct('find_files', { find_command = { 'find' } })
equal(files_picker.prompt_title, 'Find Files', 'real Find Files internal prompt title')
equal(files_picker.results_title, 'Results', 'real Find Files internal results title')
local files_options = window.get_initial_window_options(files_picker)
equal(files_options.prompt.title, '查找文件', 'real Find Files display title')
equal(files_options.results.title, '结果', 'real Find Files default Results title')
equal(files_options.preview.title, 'Grep 预览', 'real Find Files grep preview title')

local grep_picker = construct('live_grep', { vimgrep_arguments = { 'sh' } })
equal(grep_picker.prompt_title, 'Live Grep', 'real Live Grep internal prompt title')
local grep_options = window.get_initial_window_options(grep_picker)
equal(grep_options.prompt.title, '实时 Grep', 'real Live Grep display title')
equal(grep_options.preview.title, 'Grep 预览', 'real Live Grep preview title')

local default_previewer = require('telescope.config').values.file_previewer({})
equal(default_previewer:title(nil, false), '文件预览', 'real default File Preview title')
local default_picker = pickers.new({
  finder = finders.new_table({ results = {} }),
  previewer = false,
  preview_title = 'File Preview',
}, {})
equal(default_picker.prompt_title, 'Prompt', 'default internal Prompt changed')
equal(default_picker.results_title, 'Results', 'default internal Results changed')
equal(default_picker.preview_title, 'File Preview', 'explicit internal preview_title changed')
local default_options = window.get_initial_window_options(default_picker)
equal(default_options.prompt.title, '提示', 'default Prompt display title')
equal(default_options.results.title, '结果', 'default Results display title')
equal(default_options.preview.title, 'File Preview', 'explicit File Preview display title')

local previewer = Previewer:new({
  title = 'File Preview',
  dyn_title = function(_, entry) return entry.title end,
  preview_fn = function() end,
})
equal(previewer:title(nil, false), '文件预览', 'real static Previewer title')
equal(previewer:title({ title = 'Find Files' }, true), '查找文件', 'real dynamic Previewer title')
equal(previewer:title({ title = '/tmp/动态路径.lua' }, true), '/tmp/动态路径.lua',
  'real dynamic path fallback')

local action_state = require('telescope.actions.state')
local generate = require('telescope.actions.generate')
local actions = require('telescope.actions')
local original_get_picker = action_state.get_current_picker
local original_get_line = action_state.get_current_line
local original_refine = generate.refine
local refine_opts
action_state.get_current_picker = function() return grep_picker end
action_state.get_current_line = function() return 'needle' end
generate.refine = function(_, opts) refine_opts = opts end
actions.to_fuzzy_refine(1)
check(refine_opts ~= nil, 'to_fuzzy_refine did not reach real refine action')
-- The display copy handed to generate.refine is translated. to_fuzzy_refine
-- builds that string from the picker's own prompt_title, which must therefore
-- still be the English "Live Grep": that comparison is what selects the prefix,
-- so the untouched internal value is the proof that only border text moved.
equal(refine_opts.prompt_title, '查找单词 (needle)', 'refine display title not projected')
equal(grep_picker.prompt_title, 'Live Grep', 'internal Live Grep prompt_title was translated')
action_state.get_current_picker = original_get_picker
action_state.get_current_line = original_get_line
generate.refine = original_refine
local info = require('nvim-zh').status().adapters.telescope
equal(info.refine_change_title, 'covered_by_generate_refine_display_copy',
  'refine display seam missing')
check(info.uncovered:find('change_title', 1, true) == nil, 'refine change_title still listed as uncovered')

utils.notify('builtin.find_files', {
  msg = 'You need to install either find, fd, or rg',
  level = 'ERROR',
})
local notification = notifications[#notifications]
equal(notification.message, '[telescope.builtin.find_files]: 你需要安装 find、fd 或 rg 中的任意一个',
  'real Telescope notification or prefix')
equal(notification.level, vim.log.levels.ERROR, 'notification level changed')
equal(notification.opts.title, 'telescope.nvim', 'notification title changed')
utils.notify('builtin.find_files', {
  msg = 'You need to install either find, fd, or rg',
  level = 'ERROR',
  once = true,
})
equal(once_calls, 1, 'notification once flag changed')
equal(notifications[#notifications].message, notification.message, 'once notification translation')
utils.notify('builtin.find_files', { msg = '/tmp/unchanged-path', level = 'INFO' })
equal(notifications[#notifications].message, '[telescope.builtin.find_files]: /tmp/unchanged-path',
  'unknown notification fallback')

local old_window = window
local old_wrapper = window.get_initial_window_options
package.loaded['telescope.pickers.window'] = nil
window = require('telescope.pickers.window')
local new_original = window.get_initial_window_options
check(window ~= old_window and new_original ~= original_window, 'real module generation fixture failed')
dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/public.lua').refresh()
require('nvim-zh.catalog').use_sources(h.empty_catalogs())
equal(old_window.get_initial_window_options, original_window, 'real old module generation not restored')
check(window.get_initial_window_options ~= new_original, 'real new module generation not attached')
equal(old_wrapper(default_picker).prompt.title, 'Prompt', 'real old window wrapper stayed active')
equal(window.get_initial_window_options(default_picker).prompt.title, '提示',
  'real new window generation projection')

require('nvim-zh.plugins').teardown()
check(pickers.new == original_new and Previewer.title == original_title,
  'real Telescope teardown failed')
equal(window.get_initial_window_options, new_original, 'real new window generation teardown failed')
equal(utils.notify, original_notify, 'teardown changed telescope.utils.notify')
pickers._Picker.find = original_find
print('UPSTREAM_SMOKE_SPEC=PASS telescope=40aedd8 builtins=Help,FindFiles,LiveGrep refine=English notifications=true generations=true')
