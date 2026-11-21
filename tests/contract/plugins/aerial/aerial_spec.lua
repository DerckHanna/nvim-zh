local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.aerial')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/aerial.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'aerial PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'aerial' then return text end
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

package.loaded['aerial'] = nil
package.loaded['aerial.util'] = nil
package.loaded['aerial.keymap_util'] = nil
package.loaded['aerial.command'] = nil
adapter.attach(ctx)
equal(package.loaded['aerial'], nil, 'attach forced aerial to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local rendered_lines = nil
local util_mod = {
  render_centered_text = function(_, lines)
    rendered_lines = lines
  end,
}
local help_buf = nil
local keymap_util_mod = {
  set_keymaps = function(mode, _, keymaps, bufnr)
    for k, v in pairs(keymaps) do
      vim.keymap.set(mode, k, v.callback, { buffer = bufnr, desc = v.desc })
    end
  end,
  show_help = function()
    help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, true, {
      ' g?   Show default keymaps',
      ' q    Close the aerial window',
    })
  end,
}
local printed = {}
local command_mod = {
  info = function()
    print('Aerial Info')
    print('Filetype: lua')
    print('Configured backends:')
    print('  treesitter (not supported) [No treesitter parser for lua]')
    print('  lsp (supported) (attached)')
    print('Show symbols: Class, Function')
  end,
}
local aerial_mod = {
  toggle = function() return true end,
  open = function() end,
  sync_load = function() end,
  info = function() return {} end,
}

package.loaded['aerial'] = aerial_mod
package.loaded['aerial.util'] = util_mod
package.loaded['aerial.keymap_util'] = keymap_util_mod
package.loaded['aerial.command'] = command_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'aerial adapter should be active')

util_mod.render_centered_text(0, { 'No symbols', 'treesitter (not supported) [No treesitter parser for lua]' })
equal(rendered_lines[1], '暂无符号', 'No symbols translated')
equal(rendered_lines[2], 'treesitter (不支持) [未找到 lua 的 Treesitter 解析器]', 'not supported line translated')

keymap_util_mod.show_help()
local help_lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
equal(help_lines[1], ' g?   显示默认键映射', 'help line 1 translated')
equal(help_lines[2], ' q    关闭 Aerial Window', 'help line 2 translated')
vim.api.nvim_buf_delete(help_buf, { force = true })

local orig_print = _G.print
_G.print = function(s) printed[#printed + 1] = s end
command_mod.info()
_G.print = orig_print
equal(printed[1], 'Aerial 信息', 'Aerial Info title translated')
equal(printed[2], '文件类型：lua', 'Filetype line translated')
equal(printed[3], '已配置的后端：', 'Configured backends translated')
equal(printed[4], '  treesitter (不支持) [未找到 lua 的 Treesitter 解析器]', 'backend not supported translated')
equal(printed[5], '  lsp (已支持) (已附加)', 'backend supported attached translated')
equal(printed[6], '显示符号：Class, Function', 'Show symbols translated')

adapter.detach()
util_mod.render_centered_text(0, { 'No symbols' })
equal(rendered_lines[1], 'No symbols', 'detach restored render_centered_text')
print('AERIAL_CONTRACT_SPEC=PASS')
