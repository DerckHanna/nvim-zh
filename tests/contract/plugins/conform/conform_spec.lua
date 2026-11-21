local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.conform')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/conform.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'conform PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local verified = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return verified and { kind = 'fixture' } or nil, not verified and 'unsupported_revision' or nil end,
  translate = function(domain, context, text)
    if domain ~= 'conform' then return text end
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

package.loaded['conform'] = nil
package.loaded['conform.health'] = nil
adapter.attach(ctx)
equal(package.loaded['conform'], nil, 'attach forced conform to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local notifications = {}
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = msg, level = level }
end

local conform = {
  setup = function()
    vim.notify('Conform format_on_save cannot use async=true. Use format_after_save instead.', vim.log.levels.ERROR)
    return 'setup-ok'
  end,
  resolve_formatters = function()
    vim.notify("Formatter 'stylua' unavailable: Command 'stylua' not found", vim.log.levels.WARN)
    return {}
  end,
  format = function()
    vim.notify('Formatter failed. See :ConformInfo for details', vim.log.levels.ERROR)
    return false
  end,
  list_all_formatters = function() return {} end,
}

local health_logs = {}
vim.health = {
  start = function(m) health_logs[#health_logs + 1] = 'start:' .. m end,
  info = function(m) health_logs[#health_logs + 1] = 'info:' .. m end,
  warn = function(m) health_logs[#health_logs + 1] = 'warn:' .. m end,
  ok = function(m) health_logs[#health_logs + 1] = 'ok:' .. m end,
  error = function(m) health_logs[#health_logs + 1] = 'error:' .. m end,
}

local info_buf
local health = {
  check = function()
    vim.health.start('conform.nvim report')
    vim.health.info('Log file: /tmp/conform.log')
    vim.health.warn("stylua unavailable: Command 'stylua' not found")
    vim.health.ok('prettier ready (javascript)')
  end,
  show_window = function()
    info_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(info_buf, 0, -1, true, {
      'Log file: /tmp/conform.log',
      '',
      'Formatters for this buffer:',
      '<none>',
      '',
      'Other formatters:',
      "stylua unavailable: Command 'stylua' not found",
      'prettier ready (javascript) /usr/bin/prettier',
    })
  end,
}

package.loaded['conform'] = conform
package.loaded['conform.health'] = health
adapter.attach(ctx)
check(adapter.info(ctx).active, 'conform adapter should be active')

equal(conform.setup(), 'setup-ok', 'setup return value preserved')
conform.resolve_formatters()
conform.format()
equal(notifications[1].msg, 'Conform 的 format_on_save 不能使用 async=true，请改用 format_after_save。', 'setup notification translated')
equal(notifications[2].msg, "格式化器 'stylua' 不可用：未找到命令 'stylua'", 'unavailable formatter notification translated')
equal(notifications[3].msg, '格式化器执行失败。详见 :ConformInfo', 'formatter failed notification translated')

health.check()
equal(health_logs[1], 'start:conform.nvim 报告', 'health start translated')
equal(health_logs[2], 'info:日志文件：/tmp/conform.log', 'health log file translated')
equal(health_logs[3], "warn:stylua 不可用：未找到命令 'stylua'", 'health warn translated')
equal(health_logs[4], 'ok:prettier 就绪 (javascript)', 'health ok translated')

health.show_window()
local lines = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)
equal(lines[1], '日志文件：/tmp/conform.log', 'info window log line')
equal(lines[3], '当前 Buffer 的格式化器：', 'info window buffer header')
equal(lines[4], '<无>', 'info window none placeholder')
equal(lines[6], '其他格式化器：', 'info window other header')
equal(lines[7], "stylua 不可用：未找到命令 'stylua'", 'info window unavailable line')
equal(lines[8], 'prettier 就绪 (javascript) /usr/bin/prettier', 'info window ready line')
vim.api.nvim_buf_delete(info_buf, { force = true })

enabled = false
notifications = {}
conform.format()
equal(notifications[1].msg, 'Formatter failed. See :ConformInfo for details', 'disabled fallback')
enabled = true

adapter.detach()
notifications = {}
conform.format()
equal(notifications[1].msg, 'Formatter failed. See :ConformInfo for details', 'detach restored original')
print('CONFORM_CONTRACT_SPEC=PASS')
