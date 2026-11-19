-- Regression for BUG-05: the FIRST Telescope picker of a session must show
-- translated window titles. Real Telescope only loads its window/previewer
-- modules inside the first pickers.new call, and the pinned pickers.lua fires
-- User TelescopeFindPre immediately before create_layout(). The adapter must
-- sync its display projection at that boundary; before the fix the first
-- picker showed English "Results"/"Find Files" and only later pickers were
-- translated. Drives the real fixed upstream, not a mock.
local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local telescope_root = assert(vim.env.NVIM_ZH_TEST_TELESCOPE, 'fixed telescope required')
local plenary_root = assert(vim.env.NVIM_ZH_TEST_PLENARY, 'fixed plenary required')
vim.opt.runtimepath:prepend(plenary_root)
vim.opt.runtimepath:prepend(telescope_root)

-- Ensure a pristine first-use state: telescope command entry loads config only.
require('telescope')

local overrides = h.overrides()
overrides.telescope.title['Find Files'] = '查找文件'
overrides.telescope.title['Results'] = '结果'
overrides.telescope.title['Prompt'] = '提示'
overrides.telescope.title['File Preview'] = '文件预览'
h.setup({ auto = true, disabled = {} }, overrides)

local window = require('telescope.pickers.window')
local original_window = window.get_initial_window_options

-- First picker construction in this session. find() is stubbed because it
-- needs a UI; the pinned pickers.lua:540 fires User TelescopeFindPre inside
-- find() immediately before create_layout(), so we fire that exact public
-- boundary here to reproduce the real first-open sequence headlessly.
local builtin = require('telescope.builtin')
local captured
local pickers = require('telescope.pickers')
local original_find = pickers._Picker.find
pickers._Picker.find = function(self)
  captured = self
  return self
end
builtin.find_files({})
pickers._Picker.find = original_find
check(captured, 'first find_files did not construct a picker')
vim.api.nvim_exec_autocmds('User', { pattern = 'TelescopeFindPre', modeline = false })

-- The TelescopeFindPre boundary must attach the window seam before the layout
-- is created, so the very first window options are already projected.
check(window.get_initial_window_options ~= original_window,
  'window seam not attached at first TelescopeFindPre (BUG-05 regression)')
local options = window.get_initial_window_options(captured)
equal(options.results.title, '结果', 'first picker results title not translated')
-- find_files projects its picker title onto the prompt border.
equal(options.prompt.title, '查找文件', 'first picker prompt title not translated')
-- Internal behavior value stays English.
equal(captured.prompt_title, 'Find Files', 'internal prompt_title was mutated')

-- Repeated setup keeps exactly one owned TelescopeFindPre autocmd.
require('nvim-zh').setup({
  modules = { core = { enabled = false }, ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} } },
  overrides = overrides,
})
local count = 0
for _, a in ipairs(vim.api.nvim_get_autocmds({ event = 'User', pattern = 'TelescopeFindPre' })) do
  if a.group_name == 'NvimZhTelescopeFindPre' then count = count + 1 end
end
equal(count, 1, 'repeated setup duplicated TelescopeFindPre autocmd')

-- teardown removes the boundary autocmd and restores the seam.
require('nvim-zh').teardown()
local remaining = 0
for _, a in ipairs(vim.api.nvim_get_autocmds({ event = 'User', pattern = 'TelescopeFindPre' })) do
  if a.group_name == 'NvimZhTelescopeFindPre' then remaining = remaining + 1 end
end
equal(remaining, 0, 'teardown left TelescopeFindPre autocmd')
equal(window.get_initial_window_options, original_window, 'teardown did not restore window seam')

print('TELESCOPE_FIRST_PICKER_SPEC=PASS first_titles=zh internal=english autocmd=idempotent teardown=clean')