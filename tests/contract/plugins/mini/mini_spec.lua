local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.mini')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/mini.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'mini PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'mini' then return text end
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

package.loaded['mini.statusline'] = nil
package.loaded['mini.surround'] = nil
package.loaded['mini.ai'] = nil
adapter.attach(ctx)
equal(package.loaded['mini.statusline'], nil, 'attach forced mini.statusline to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local sl_mod = {
  section_mode = function(args)
    if args and args.short then return 'N', 'MiniStatuslineModeNormal' end
    return 'Normal', 'MiniStatuslineModeNormal'
  end,
}

local captured_prompt = nil
local echoed = {}
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks)
  local parts = {}
  for _, ch in ipairs(chunks or {}) do parts[#parts + 1] = ch[1] end
  echoed[#echoed + 1] = table.concat(parts)
end

local surround_mod = {
  user_input = function(prompt)
    captured_prompt = '(mini.surround) ' .. prompt
    return 'fn'
  end,
  find = function()
    vim.api.nvim_echo({
      { '(mini.surround) ', 'WarningMsg' },
      { [[No surrounding ")" found within 20 lines and `config.search_method = 'cover'`.]] },
    }, true, {})
  end,
}

package.loaded['mini.statusline'] = sl_mod
package.loaded['mini.surround'] = surround_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'mini adapter should be active')

local mode, hl = sl_mod.section_mode({})
equal(mode, '普通', 'Normal mode translated')
equal(hl, 'MiniStatuslineModeNormal', 'mode highlight preserved')
local short_mode = sl_mod.section_mode({ short = true })
equal(short_mode, 'N', 'short mode code not translated')

surround_mod.user_input('Function name')
equal(captured_prompt, '(mini.surround) 函数名', 'MiniSurround.user_input prompt translated')

surround_mod.find()
equal(echoed[1], [[(mini.surround) 未找到包围符 ")"（范围：20 行内，`config.search_method = 'cover'`）。]],
  'MiniSurround feedback translated')

adapter.detach()
equal(sl_mod.section_mode({}), 'Normal', 'detach restored section_mode')
vim.api.nvim_echo = orig_echo
print('MINI_CONTRACT_SPEC=PASS')
