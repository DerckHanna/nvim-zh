local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = vim.env.NVIM_ZH_TEST_WHICH_KEY
assert(upstream, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(upstream)

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/which-key.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'which-key PO contains forbidden term: ' .. forbidden)
end

local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

local wk = require('which-key')
local config = require('which-key.config')
local view = require('which-key.view')
local original_setup = wk.setup
local zh = require('nvim-zh')
local setup_opts = {
  modules = {
    core = { enabled = false },
    ui = { notify = true, prompts = false, echo = false },
    plugins = { auto = true, disabled = {} },
  },
}
zh.setup(setup_opts)
check(wk.setup ~= original_setup, 'real which-key setup was not attached')
local desc_count = #config.replace.desc
local info = zh.status().adapters['which-key']
check(info.active and info.seam == 'replace.desc', 'real which-key desc seam is not active')

-- Use real preset/plugin text, while proving that only the display projection
-- changes and the original mapping remains byte/identity identical.
local presets = require('which-key.plugins.presets')
local preset_mapping
for _, mapping in ipairs(presets.operators) do
  if mapping.desc == 'Delete' then preset_mapping = mapping end
end
check(preset_mapping, 'fixed upstream Delete preset missing')
equal(view.replace('desc', preset_mapping.desc), '删除', 'preset default description')
equal(preset_mapping.desc, 'Delete', 'preset source mapping was mutated')
equal(view.replace('desc', 'Last position of cursor in insert mode'), '插入模式下光标最后位置', 'mark label')
equal(view.replace('desc', 'last yank'), '上次复制', 'register label')
equal(view.replace('desc', 'Spelling Suggestions'), '拼写建议', 'spelling entry')
equal(view.replace('desc', 'window'), 'Window', 'window terminology')
equal(view.replace('desc', 'registers'), 'Register', 'registers terminology')
equal(view.replace('desc', 'Last change in current buffer'), '当前 Buffer 最后一次修改的位置', 'buffer terminology')
equal(view.replace('desc', 'alternate buffer'), '备用 Buffer', 'alternate buffer terminology')

local rhs = function() return 'original-rhs' end
local mapping = { lhs = '<leader>d', rhs = rhs, desc = 'Delete', buffer = 7 }
local node = {
  key = mapping.lhs,
  keys = mapping.lhs,
  desc = mapping.desc,
  mapping = mapping,
  keymap = mapping,
  can_expand = function() return true end,
  count = function() return 0 end,
  is_group = function() return false end,
}
equal(view.item(node).desc, '删除', 'mapping display description')
check(mapping.lhs == '<leader>d' and mapping.rhs == rhs and mapping.desc == 'Delete' and mapping.buffer == 7,
  'original mapping identity/rhs/shortcut/buffer changed')

local function generated_count(count)
  local group = {
    key = '<leader>g',
    keys = '<leader>g',
    can_expand = function() return false end,
    count = function() return count end,
    is_group = function() return true end,
  }
  return view.item(group).desc
end
equal(generated_count(1), '+1 个键映射', 'generated singular count')
equal(generated_count(2), '+2 个键映射', 'generated plural count')
equal(generated_count(17), '+17 个键映射', 'generated count lost its number')

-- Both nvim-zh setup and which-key's own setup are idempotent. The latter may
-- rebuild replace.desc and is the deliberate exception to external-list ownership.
zh.setup(setup_opts)
equal(#config.replace.desc, desc_count, 'repeated nvim-zh setup duplicated formatter')
local wrapped_setup = wk.setup
wk.setup({ notify = false })
check(wk.setup == wrapped_setup, 'public setup replaced its owned wrapper')
equal(#config.replace.desc, desc_count, 'public which-key setup did not restore exactly one formatter')
equal(view.replace('desc', 'Delete'), '删除', 'translation after public setup rebuild')

-- A real new module table is a new generation: clean the old wrapper and attach
-- the new public function through the current refresh(callback) API.
package.loaded['which-key'] = nil
local new_wk = require('which-key')
local new_original_setup = new_wk.setup
check(new_wk ~= wk, 'module generation fixture did not create a new table')
local refreshed, refresh_result = false, nil
zh.refresh(function(result)
  refreshed, refresh_result = true, result
end)
check(vim.wait(10000, function() return refreshed end, 10), 'refresh callback did not run')
check(refresh_result and refresh_result.ok, 'refresh failed: ' .. vim.inspect(refresh_result))
check(wk.setup == original_setup, 'old module generation wrapper was not cleaned')
check(new_wk.setup ~= new_original_setup, 'new real module generation was not attached')
equal(#config.replace.desc, desc_count, 'module generation duplicated formatter')

-- Exact title routing happens once at vim.notify. notify_once still deduplicates
-- the original message, and which-key's title/level remain untouched.
notifications = {}
local observed = zh.stats().runtime.observed
local util = require('which-key.util')
util.warn('Usage: WhichKey [mode] [keys]', { once = true })
util.warn('Usage: WhichKey [mode] [keys]', { once = true })
equal(#notifications, 1, 'which-key once notification was not deduplicated')
equal(notifications[1].msg, '用法：WhichKey [mode] [keys]', 'notification domain translation')
equal(notifications[1].level, vim.log.levels.WARN, 'notification level changed')
equal(notifications[1].opts.title, 'which-key.nvim', 'notification title changed')
equal(zh.stats().runtime.observed - observed, 1, 'notification was translated/observed more than once')
local route
for _, source in ipairs(zh.status().ui.sources) do
  if source.title == 'which-key.nvim' then route = source end
end
check(route and route.domain == 'which-key' and route.context == 'notification', 'notification source domain missing')

require('nvim-zh.plugins').teardown()
check(new_wk.setup == new_original_setup, 'real new generation teardown failed')
equal(#config.replace.desc, desc_count - 1, 'real formatter teardown failed')
print('WHICH_KEY_UPSTREAM_SPEC=PASS commit=3aab214 presets,count,mapping,notify,setup,generation')
