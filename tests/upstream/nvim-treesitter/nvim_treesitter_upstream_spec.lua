local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_NVIM_TREESITTER
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('nvim-treesitter', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local echoes = {}
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, opts)
  if chunks and chunks[1] and type(chunks[1][1]) == 'string' then
    echoes[#echoes + 1] = chunks[1][1]
  end
  return orig_echo(chunks, history, opts)
end

local log = require('nvim-treesitter.log')
local config = require('nvim-treesitter.config')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })

local info = zh.status().adapters['nvim-treesitter']
check(info and info.active, 'nvim-treesitter adapter should be active on fixed upstream')

config.norm_languages({ 'nonexistent_lang_xyz' })
equal(echoes[#echoes], '[nvim-treesitter] warning: 跳过不支持的语言：nonexistent_lang_xyz',
  'real norm_languages unsupported language warning translated')

log.info('All parsers are up-to-date')
equal(echoes[#echoes], '[nvim-treesitter]: 所有解析器均已是最新', 'real log.info translated')

vim.api.nvim_echo = orig_echo
require('nvim-zh.plugins').teardown()
print('NVIM_TREESITTER_UPSTREAM_SPEC=PASS')
