local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local plenary = vim.env.NVIM_ZH_TEST_PLENARY
local upstream = vim.env.NVIM_ZH_TEST_CMAKE_TOOLS
assert(plenary and upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(plenary)
vim.opt.runtimepath:prepend(upstream)

local zh = require('nvim-zh')
zh.register_adapter_source('cmake-tools', upstream)
zh.setup({
  modules = {
    core = { enabled = false },
    ui = { notify = true, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
})

local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

local cmake = require('cmake-tools')
local log = require('cmake-tools.log')
require('nvim-zh.plugins').setup({ auto = true, lazy_load = true, disabled = {} })

local info = zh.status().adapters['cmake-tools']
check(info and info.active, 'cmake-tools adapter should be active on fixed upstream')

log.error('You need to configure it first')
equal(notifications[#notifications].msg, '请先执行 CMake 配置', 'real log.error notification translated')
equal(notifications[#notifications].opts.title, 'CMakeTools', 'notification title preserved')

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, 'p')
vim.fn.writefile({ 'cmake_minimum_required(VERSION 3.16)', 'project(demo)' }, tmpdir .. '/CMakeLists.txt')
local old_cwd = vim.fn.getcwd()
vim.cmd.cd(tmpdir)
cmake.setup({ cmake_generate_options = {} })

local captured_prompt = nil
local orig_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  captured_prompt = opts and opts.prompt
  if on_choice then on_choice(nil) end
end
cmake.select_build_type(function() end)
vim.ui.select = orig_select
vim.cmd.cd(old_cwd)

equal(captured_prompt, '选择构建类型', 'real cmake.select_build_type prompt translated')

require('nvim-zh.plugins').teardown()
print('CMAKE_TOOLS_UPSTREAM_SPEC=PASS')
