local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.nvim_treesitter')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/nvim-treesitter.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'nvim-treesitter PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'nvim-treesitter' then return text end
    return require('nvim-zh.adapters.common').translate(domain, context, text)
  end,
}

require('nvim-zh').setup({
  modules = {
    core = { enabled = false },
    ui = { notify = false, prompts = false, echo = false },
    plugins = { auto = false, disabled = {} },
  },
})

package.loaded['nvim-treesitter.log'] = nil
package.loaded['nvim-treesitter.health'] = nil
adapter.attach(ctx)
equal(package.loaded['nvim-treesitter.log'], nil, 'attach forced log module to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local echoed = {}
local Logger = {}
function Logger:info(m, ...)
  local m1 = m:format(...)
  echoed[#echoed + 1] = ('[nvim-treesitter]: %s'):format(m1)
end
function Logger:warn(m, ...)
  local m1 = m:format(...)
  echoed[#echoed + 1] = ('[nvim-treesitter] warning: %s'):format(m1)
end
function Logger:error(m, ...)
  local m1 = m:format(...)
  echoed[#echoed + 1] = ('[nvim-treesitter] error: %s'):format(m1)
  return m1
end

local log_mod = {
  Logger = Logger,
  new = function(c) return setmetatable({ ctx = c }, { __index = Logger }) end,
}

package.loaded['nvim-treesitter.log'] = log_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'nvim-treesitter adapter should be active')

local logger = log_mod.new('install/lua')
logger:info('Downloading %s...', 'tree-sitter-lua')
logger:info('Compiling parser')
logger:info('Language installed')
logger:warn('skipping unsupported language: %s', 'foo_lang')
local err_ret = logger:error('Parser not available for language "%s"', 'foo_lang')

equal(echoed[1], '[nvim-treesitter]: 正在下载 tree-sitter-lua...', 'info Downloading translated')
equal(echoed[2], '[nvim-treesitter]: 正在编译解析器', 'info Compiling parser translated')
equal(echoed[3], '[nvim-treesitter]: 语言解析器已安装', 'info Language installed translated')
equal(echoed[4], '[nvim-treesitter] warning: 跳过不支持的语言：foo_lang', 'warn skipping unsupported language translated')
equal(echoed[5], '[nvim-treesitter] error: 语言 "foo_lang" 没有可用的解析器', 'error Parser not available translated')
equal(err_ret, '语言 "foo_lang" 没有可用的解析器', 'Logger:error return value translated')

enabled = false
echoed = {}
logger:info('All parsers are up-to-date')
equal(echoed[1], '[nvim-treesitter]: All parsers are up-to-date', 'disabled fallback')
enabled = true

adapter.detach()
echoed = {}
logger:info('All parsers are up-to-date')
equal(echoed[1], '[nvim-treesitter]: All parsers are up-to-date', 'detach restored original')
print('NVIM_TREESITTER_CONTRACT_SPEC=PASS')
