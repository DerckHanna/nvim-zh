local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.cmake_tools')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/cmake-tools.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'cmake-tools PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'cmake-tools' then return text end
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

package.loaded['cmake-tools'] = nil
package.loaded['cmake-tools.log'] = nil
adapter.attach(ctx)
equal(package.loaded['cmake-tools'], nil, 'attach forced cmake-tools to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local last_prompt = nil
vim.ui.select = function(_, opts)
  last_prompt = opts and opts.prompt
end

local notifications = {}
local log_mod = {
  notify = function(msg, level)
    notifications[#notifications + 1] = { msg = msg, level = level }
  end,
}
local cmake_mod = {
  select_build_type = function()
    vim.ui.select({ 'Debug', 'Release' }, { prompt = 'Select build type' }, function() end)
  end,
  select_build_target = function()
    vim.ui.select({ 'all' }, { prompt = 'Select build target' }, function() end)
  end,
}

package.loaded['cmake-tools'] = cmake_mod
package.loaded['cmake-tools.log'] = log_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'cmake-tools adapter should be active')

cmake_mod.select_build_type()
equal(last_prompt, '选择构建类型', 'select_build_type prompt translated')
cmake_mod.select_build_target()
equal(last_prompt, '选择构建 Target', 'select_build_target prompt translated')

log_mod.notify('Cannot find CMakeLists.txt at cwd (/tmp/proj).', vim.log.levels.ERROR)
log_mod.notify('You need to configure it first', vim.log.levels.WARN)
equal(notifications[1].msg, '在当前工作目录 (/tmp/proj) 下找不到 CMakeLists.txt。', 'missing CMakeLists notification translated')
equal(notifications[2].msg, '请先执行 CMake 配置', 'configure first notification translated')

adapter.detach()
cmake_mod.select_build_type()
equal(last_prompt, 'Select build type', 'detach restored original select_build_type')
print('CMAKE_TOOLS_CONTRACT_SPEC=PASS')
