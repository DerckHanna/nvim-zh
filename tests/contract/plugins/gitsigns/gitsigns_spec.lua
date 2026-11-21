local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.gitsigns')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/gitsigns.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'gitsigns PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'gitsigns' then return text end
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

package.loaded['gitsigns.popup'] = nil
package.loaded['gitsigns.message'] = nil
package.loaded['gitsigns.actions'] = nil
adapter.attach(ctx)
equal(package.loaded['gitsigns.popup'], nil, 'attach forced gitsigns.popup to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local created_spec = nil
local popup_mod = {
  create = function(lines_spec)
    created_spec = lines_spec
  end,
  update = function(_, _, lines_spec)
    created_spec = lines_spec
  end,
}

local notified = {}
local msg_mod = {
  warn = function(fmt, ...)
    notified[#notified + 1] = fmt:format(...)
  end,
  error = function(fmt, ...)
    notified[#notified + 1] = fmt:format(...)
  end,
  error_once = function(fmt, ...)
    notified[#notified + 1] = fmt:format(...)
  end,
}

local echoed = {}
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks)
  echoed[#echoed + 1] = chunks[1][1]
end

local actions_mod = {
  stage_hunk = function()
    vim.api.nvim_echo({ { 'No hunk to stage', 'WarningMsg' } }, false, {})
  end,
  reset_buffer = function()
    vim.api.nvim_echo({ { 'No unstaged changes in the buffer to reset', 'WarningMsg' } }, false, {})
  end,
}

package.loaded['gitsigns.popup'] = popup_mod
package.loaded['gitsigns.message'] = msg_mod
package.loaded['gitsigns.actions'] = actions_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'gitsigns adapter should be active')

local raw_spec = {
  { { 'Hunk 1 of 3', 'Title' } },
  { { 'local x = 1', { { hl_group = 'DiffAdd', start_row = 0 } } } },
}
popup_mod.create(raw_spec)
equal(created_spec[1][1][1], '第 1 / 3 个 Hunk', 'popup header translated')
equal(created_spec[2][1][1], 'local x = 1', 'diff code line preserved untouched')
equal(raw_spec[1][1][1], 'Hunk 1 of 3', 'original lines_spec not mutated')

msg_mod.error('%s is not a valid function or action', 'foo_act')
equal(notified[1], 'foo_act 不是有效的函数或动作', 'message.error translated')

actions_mod.stage_hunk()
actions_mod.reset_buffer()
equal(echoed[1], '没有可暂存的 Hunk', 'stage_hunk echo translated')
equal(echoed[2], '当前 Buffer 中没有可重置的未暂存更改', 'reset_buffer echo translated')

adapter.detach()
popup_mod.create(raw_spec)
equal(created_spec[1][1][1], 'Hunk 1 of 3', 'detach restored popup.create')
vim.api.nvim_echo = orig_echo
print('GITSIGNS_CONTRACT_SPEC=PASS')
