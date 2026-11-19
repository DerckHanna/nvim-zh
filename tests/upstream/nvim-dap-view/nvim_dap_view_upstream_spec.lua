local root = assert(vim.env.NVIM_ZH_TEST_NVIM_DAP_VIEW)
vim.opt.rtp:prepend(assert(vim.env.NVIM_ZH_TEST_NVIM_DAP))
vim.opt.rtp:prepend(root)
vim.o.columns = 115

local zh = require('nvim-zh')
zh.register_adapter_source('nvim-dap-view', root)
local opts = { modules = { core = { enabled = false }, plugins = { lazy_load = false } } }
zh.setup(opts)
assert(package.loaded['dap-view'] == nil, 'adapter loaded the target eagerly')

local view = require('dap-view')
local dap = require('dap')
local state = require('dap-view.state')
local winbar_module = require('dap-view.options.winbar')
local refresh = winbar_module.set_winbar_opt

local function winbar()
  return vim.api.nvim_eval_statusline(vim.wo[state.winnr].winbar, {
    winid = state.winnr, use_winbar = true,
  }).str
end

local function line()
  return vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)[1]
end

view.setup({ winbar = {
  sections = { 'scopes', 'threads', 'breakpoints', 'watches' },
  default_section = 'scopes', base_sections = { scopes = { keymap = 'L' } },
} })
view.open()
assert(winbar():find('变量 [L]', 1, true), winbar())
assert(line() == '无活动调试会话', line())
view.jump_to_view('scopes')
assert(vim.fn.maparg('L', 'n', false, true).desc == '变量')
assert(require('dap-view.setup').config.winbar.base_sections.scopes.label == 'Scopes')

zh.setup(opts)
assert(winbar_module.set_winbar_opt == refresh, 'repeat setup replaced upstream function')
local adapter = zh.status().adapters['nvim-dap-view']
assert(adapter.surfaces.titles.active and adapter.surfaces.panel_messages.active, vim.inspect(adapter))

local session = dap.session
dap.session = function() return {} end
view.show_view('threads')
assert(line() == '没有暂停的线程', line())
state.threads_error = 'No stopped thread'
view.show_view('threads')
assert(line() == state.threads_error, 'adapter error with matching text was translated')
state.threads_error = nil
dap.session = session

local calls = 0
view.setup({ winbar = { show_keymap_hints = false, base_sections = {
  scopes = { label = 'Scopes' },
  threads = { label = function(width, section)
    assert(width > 0 and type(section) == 'string')
    calls = calls + 1
    return 'Threads'
  end },
} } })
view.show_view('breakpoints')
assert(winbar():find(' Scopes ', 1, true) and winbar():find(' Threads ', 1, true), winbar())
assert(winbar():find(' 断点 ', 1, true) and not winbar():find('[B]', 1, true), winbar())
assert(line() == '暂无断点' and calls > 0, line())

local external = function() vim.wo[state.winnr][0].winbar = 'external' end
winbar_module.set_winbar_opt = external
zh.setup(opts)
assert(winbar_module.set_winbar_opt == external)
view.show_view('threads')
assert(winbar() == 'external')
assert(zh.status().adapters['nvim-dap-view'].surfaces.titles.status == 'external_override')
winbar_module.set_winbar_opt = refresh
view.close()

zh.teardown()
assert(winbar_module.set_winbar_opt == refresh)
view.open()
view.show_view('breakpoints')
assert(winbar():find(' Breakpoints ', 1, true) and line() == 'No breakpoints')
view.close()
print('NVIM_DAP_VIEW_UPSTREAM_SPEC=PASS')
