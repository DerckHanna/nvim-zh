local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.snacks')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/snacks.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'snacks PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' }, nil end,
  translate = function(domain, context, text)
    if domain ~= 'snacks' then return text end
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

package.loaded['snacks'] = nil
package.loaded['snacks.dashboard'] = nil
package.loaded['snacks.picker.util'] = nil
package.loaded['snacks.notify'] = nil
package.loaded['snacks.health'] = nil
adapter.attach(ctx)
equal(package.loaded['snacks'], nil, 'attach forced snacks to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'not_loaded reason')

local dash_mod = {
  sections = {
    keys = function()
      return function()
        return {
          { key = 'f', desc = 'Find File' },
          { key = 'q', desc = 'Quit' },
          { key = 'x', desc = 'Custom Action' },
        }
      end
    end,
    startup = function()
      return {
        text = {
          { '⚡ Neovim loaded ', hl = 'footer' },
          { '10/10', hl = 'special' },
          { ' plugins in ', hl = 'footer' },
          { '25ms', hl = 'special' },
        },
      }
    end,
  },
  Dashboard = {
    format_field = function(_, item, field) return { item[field] } end,
  },
}

local util_mod = {
  title = function(str)
    return table.concat(vim.tbl_map(function(s)
      return s:sub(1, 1):upper() .. s:sub(2)
    end, vim.split(str, '_')), ' ')
  end,
}

local notified = {}
local notify_mod = {
  notify = function(msg)
    notified[#notified + 1] = msg
  end,
}

local health_logs = {}
local orig_vim_health = package.loaded['vim.health']
package.loaded['vim.health'] = {
  start = function(m) health_logs[#health_logs + 1] = 'start:' .. m end,
  ok = function(m) health_logs[#health_logs + 1] = 'ok:' .. m end,
  warn = function(m) health_logs[#health_logs + 1] = 'warn:' .. m end,
  error = function(m) health_logs[#health_logs + 1] = 'error:' .. m end,
  info = function(m) health_logs[#health_logs + 1] = 'info:' .. m end,
}

local health_mod = {
  check = function()
    require('vim.health').ok('setup called')
    require('vim.health').ok('setup {enabled}')
    require('vim.health').warn('setup {disabled}')
    require('vim.health').ok('`Snacks.picker.files()` is available')
  end,
}

package.loaded['snacks.dashboard'] = dash_mod
package.loaded['snacks.picker.util'] = util_mod
package.loaded['snacks.notify'] = notify_mod
package.loaded['snacks.health'] = health_mod
adapter.attach(ctx)
check(adapter.info(ctx).active, 'snacks adapter should be active')

local items = dash_mod.sections.keys()()
equal(items[1].desc, '查找文件', 'dashboard Find File translated')
equal(items[2].desc, '退出', 'dashboard Quit translated')
equal(items[3].desc, 'Custom Action', 'dashboard custom item preserved')

local startup = dash_mod.sections.startup()
equal(startup.text[1][1], '⚡ Neovim 已加载 ', 'dashboard startup prefix translated')
equal(startup.text[3][1], ' 个插件，耗时 ', 'dashboard startup middle translated')

equal(util_mod.title('files'), '文件', 'picker title files translated')
equal(util_mod.title('git_branches'), 'Git 分支', 'picker title git_branches translated')
equal(util_mod.title('lsp_symbols'), 'LSP 文档符号', 'picker title lsp_symbols translated')

notify_mod.notify('No results found for `files`')
notify_mod.notify('Only open buffers can be deleted')
equal(notified[1], '未找到 `files` 的结果', 'picker No results notification translated')
equal(notified[2], '仅可删除已打开的 Buffer', 'picker buffers notification translated')

health_mod.check()
equal(health_logs[1], 'ok:已调用 setup', 'health setup called translated')
equal(health_logs[2], 'ok:初始化配置 {enabled}', 'health setup {enabled} translated')
equal(health_logs[3], 'warn:初始化配置 {disabled}', 'health setup {disabled} translated')
equal(health_logs[4], 'ok:`Snacks.picker.files()` 可用', 'health picker files available translated')

adapter.detach()
equal(util_mod.title('files'), 'Files', 'detach restored picker util.title')
package.loaded['vim.health'] = orig_vim_health
print('SNACKS_CONTRACT_SPEC=PASS')
