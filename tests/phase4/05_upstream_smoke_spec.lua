local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal
local which_key_root = vim.env.NVIM_ZH_TEST_WHICH_KEY
local telescope_root = vim.env.NVIM_ZH_TEST_TELESCOPE
local plenary_root = vim.env.NVIM_ZH_TEST_PLENARY
if not which_key_root or not telescope_root or not plenary_root then
  print('UPSTREAM_SMOKE_SPEC=SKIP set NVIM_ZH_TEST_WHICH_KEY/NVIM_ZH_TEST_TELESCOPE/NVIM_ZH_TEST_PLENARY')
  return
end
vim.opt.runtimepath:prepend(which_key_root)
vim.opt.runtimepath:prepend(telescope_root)
vim.opt.runtimepath:prepend(plenary_root)

require('which-key').setup({})
local wk_config = require('which-key.config')
local wk_view = require('which-key.view')
require('telescope').setup({})
local pickers = require('telescope.pickers')
local Previewer = require('telescope.previewers.previewer')
local original_new = pickers.new
local original_desc_count = #wk_config.replace.desc
require('nvim-zh').setup({
  modules = {
    ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})
check(pickers.new ~= original_new, 'real Telescope adapter not attached')
equal(#wk_config.replace.desc, original_desc_count + 1, 'real which-key adapter not attached')

local mapping = { lhs = '<leader>sf', rhs = ':write<CR>', desc = 'Save File' }
equal(wk_view.replace('desc', mapping.desc), '保存文件', 'real which-key built-in PO translation')
check(mapping.rhs == ':write<CR>' and mapping.desc == 'Save File', 'real mapping mutated')
local finder = { real_fixture = true }
local entry_maker = function(value) return value end
local attach_mappings = function() return true end
local picker = pickers.new({
  prompt_title = 'Find Files', preview_title = 'Git Commits', previewer = false,
  finder = finder, entry_maker = entry_maker, attach_mappings = attach_mappings,
}, { results_title = 'Help Tags' })
equal(picker.prompt_title, '查找文件', 'real Telescope prompt title')
equal(picker.results_title, '帮助标签', 'real Telescope results title')
equal(picker.preview_title, 'Git 提交', 'real Telescope preview title')
check(picker.finder == finder and picker.attach_mappings == attach_mappings, 'real Telescope behavior objects changed')
local previewer = Previewer:new({ title = 'Help Tags', dyn_title = function(_, entry) return entry.title end })
equal(previewer:title({}, false), '帮助标签', 'real Telescope static previewer title')
equal(previewer:title({ title = 'Find Files' }, true), '查找文件', 'real Telescope dynamic previewer title')

require('nvim-zh.plugins').teardown()
check(pickers.new == original_new, 'real Telescope teardown failed')
equal(#wk_config.replace.desc, original_desc_count, 'real which-key teardown failed')
print('UPSTREAM_SMOKE_SPEC=PASS which-key=3aab214 telescope=40aedd8 real_public_seams=true')
