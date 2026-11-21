local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.blink_cmp')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/blink-cmp.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'blink-cmp PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'blink-cmp' then return text end
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

package.loaded['blink.cmp.lib.utils'] = nil
package.loaded['blink.cmp.health'] = nil
adapter.attach(ctx)
equal(package.loaded['blink.cmp.lib.utils'], nil, 'attach forced blink.cmp.lib.utils to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local last_chunks = nil
local utils_mod = {
  notify = function(msg)
    last_chunks = msg
  end,
}

local health_logs = {}
vim.health = {
  start = function(m) health_logs[#health_logs + 1] = 'start:' .. m end,
  ok = function(m) health_logs[#health_logs + 1] = 'ok:' .. m end,
  warn = function(m) health_logs[#health_logs + 1] = 'warn:' .. m end,
  error = function(m) health_logs[#health_logs + 1] = 'error:' .. m end,
  info = function(m) health_logs[#health_logs + 1] = 'info:' .. m end,
}

local health_mod = {
  check = function()
    vim.health.start('System')
    vim.health.ok('curl is installed')
    vim.health.ok('Your system is supported by pre-built binaries (x86_64-unknown-linux-gnu)')
    vim.health.start('Sources')
    vim.health.start('Default sources')
  end,
}

package.loaded['blink.cmp.lib.utils'] = utils_mod
package.loaded['blink.cmp.health'] = health_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'blink-cmp adapter should be active')

local raw_msg = { { 'No build log available' } }
utils_mod.notify(raw_msg)
equal(last_chunks[1][1], '没有可用的构建日志', 'utils.notify chunk translated')
equal(raw_msg[1][1], 'No build log available', 'original chunk array not mutated')

health_mod.check()
equal(health_logs[1], 'start:系统环境', 'health System translated')
equal(health_logs[2], 'ok:curl 已安装', 'health curl installed translated')
equal(health_logs[3], 'ok:你的系统支持预编译二进制文件 (x86_64-unknown-linux-gnu)', 'health system triple translated')
equal(health_logs[4], 'start:补全源', 'health Sources translated')
equal(health_logs[5], 'start:默认补全源', 'health Default sources translated')

adapter.detach()
utils_mod.notify(raw_msg)
equal(last_chunks[1][1], 'No build log available', 'detach restored utils.notify')
print('BLINK_CMP_CONTRACT_SPEC=PASS')
