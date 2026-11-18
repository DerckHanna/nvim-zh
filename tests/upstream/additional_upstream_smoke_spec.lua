local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local lazy_root = vim.env.NVIM_ZH_TEST_LAZY
local tree_root = vim.env.NVIM_ZH_TEST_NVIM_TREE
local cmp_root = vim.env.NVIM_ZH_TEST_NVIM_CMP
assert(lazy_root and tree_root and cmp_root, 'fixed upstream sources are required')
vim.opt.runtimepath:prepend(lazy_root)
vim.opt.runtimepath:prepend(tree_root)
vim.opt.runtimepath:prepend(cmp_root)

local expected = {
  { '<C-]>', 'CD', '切换目录' },
  { '<C-e>', 'Open: In Place', '原地打开' },
  { '<C-k>', 'Info', '信息' },
  { '<C-r>', 'Rename: Omit Filename', '重命名：省略文件名' },
  { '<C-t>', 'Open: New Tab', '打开：新标签页' },
  { '<C-v>', 'Open: Vertical Split', '打开：垂直分屏' },
  { '<C-x>', 'Open: Horizontal Split', '打开：水平分屏' },
  { '<BS>', 'Close Directory', '关闭目录' },
  { '<CR>', 'Open', '打开' },
  { '<Del>', 'Delete', '删除' },
  { '<Tab>', 'Open Preview', '打开预览' },
  { '>', 'Next Sibling', '下一个同级节点' },
  { '<', 'Previous Sibling', '上一个同级节点' },
  { '.', 'Run Command', '运行命令' },
  { '-', 'Up', '上级目录' },
  { 'a', 'Create File Or Directory', '创建文件或目录' },
  { 'bd', 'Delete Bookmarked', '删除书签节点' },
  { 'bt', 'Trash Bookmarked', '将书签节点移到回收站' },
  { 'bmv', 'Move Bookmarked', '移动书签节点' },
  { 'B', 'Toggle Filter: No Buffer', '切换过滤器：无 Buffer' },
  { 'c', 'Copy', '复制' },
  { 'C', 'Toggle Filter: Git Clean', '切换过滤器：Git 无改动' },
  { '[c', 'Prev Git', '上一个 Git 变更' },
  { ']c', 'Next Git', '下一个 Git 变更' },
  { 'd', 'Delete', '删除' },
  { 'D', 'Trash', '移到回收站' },
  { 'E', 'Expand All', '展开全部' },
  { 'e', 'Rename: Basename', '重命名：文件名' },
  { ']e', 'Next Diagnostic', '下一个诊断' },
  { '[e', 'Prev Diagnostic', '上一个诊断' },
  { 'F', 'Live Filter: Clear', '实时过滤：清除' },
  { 'f', 'Live Filter: Start', '实时过滤：开始' },
  { 'g?', 'Help', '帮助' },
  { 'gy', 'Copy Absolute Path', '复制绝对路径' },
  { 'ge', 'Copy Basename', '复制文件名' },
  { 'H', 'Toggle Filter: Dotfiles', '切换过滤器：点文件' },
  { 'I', 'Toggle Filter: Git Ignored', '切换过滤器：Git 忽略' },
  { 'J', 'Last Sibling', '最后一个同级节点' },
  { 'K', 'First Sibling', '第一个同级节点' },
  { 'L', 'Toggle Group Empty', '切换空目录组' },
  { 'M', 'Toggle Filter: No Bookmark', '切换过滤器：无书签' },
  { 'm', 'Toggle Bookmark', '切换书签' },
  { 'o', 'Open', '打开' },
  { 'O', 'Open: No Window Picker', '打开：不使用 Window 选择器' },
  { 'p', 'Paste', '粘贴' },
  { 'gp', 'Move', '移动' },
  { 'P', 'Parent Directory', '父目录' },
  { 'q', 'Close', '关闭' },
  { 'r', 'Rename', '重命名' },
  { 'R', 'Refresh', '刷新' },
  { 's', 'Run System', '使用系统打开' },
  { 'S', 'Search', '搜索' },
  { 'u', 'Rename: Full Path', '重命名：完整路径' },
  { 'U', 'Toggle Filter: Custom', '切换过滤器：自定义' },
  { 'W', 'Collapse All', '折叠全部' },
  { 'x', 'Cut', '剪切' },
  { 'y', 'Copy Name', '复制名称' },
  { 'Y', 'Copy Relative Path', '复制相对路径' },
  { '<2-LeftMouse>', 'Open', '打开' },
  { '<2-RightMouse>', 'CD', '切换目录' },
}

local overrides = h.overrides()
overrides['nvim-tree'] = { mapping = {}, notification = {
  ['No bookmarks to delete.'] = '没有可删除的书签。',
  ['Cannot create: path already exists: %s'] = '无法创建：路径已存在：%s',
} }
for _, item in ipairs(expected) do
  overrides['nvim-tree'].mapping[item[2]] = item[3]
end

local notifications = {}
local notify_spy = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end
vim.notify = notify_spy
local zh = require('nvim-zh')
zh.register_catalog('nvim-tree', function()
  local entries = {
    { context = 'notification', msgid = 'No bookmarks to delete.', msgstr = '没有可删除的书签。' },
    { context = 'notification', msgid = 'Cannot create: path already exists: %s', msgstr = '无法创建：路径已存在：%s' },
  }
  local seen = {}
  for _, item in ipairs(expected) do
    if not seen[item[2]] then
      entries[#entries + 1] = { context = 'mapping', msgid = item[2], msgstr = item[3] }
      seen[item[2]] = true
    end
  end
  return { schema = 1, domain = 'nvim-tree', locale = 'zh_CN', entries = entries }
end, { locale = 'zh_CN', source = 'pinned-test-catalog' })
zh.setup({
  modules = {
    ui = { notify = true, prompts = false, echo = false },
    plugins = { auto = true, lazy_load = true, disabled = {} },
  },
  overrides = overrides,
  missing = { enabled = true, max_entries = 64 },
})
check(package.loaded['nvim-tree'] == nil, 'nvim-zh setup forced real nvim-tree to load')

local lazy = require('lazy')
local cmp = require('cmp')
check(type(lazy.setup) == 'function', 'real lazy.setup missing')
check(type(cmp.setup) == 'table', 'real nvim-cmp public setup missing')
local cmp_info = zh.status().plugins['nvim-cmp']
check(not cmp_info.active and cmp_info.reason == 'inventory_only_no_cmp_owned_fixed_labels',
  'nvim-cmp inventory-only exclusion changed')

local order = {}
local setup_events, lazy_events = 0, 0
local original_tree_setup, original_default
local probe = vim.api.nvim_create_augroup('NvimZhTreeRealOrderProbe', { clear = true })
vim.api.nvim_create_autocmd('User', {
  group = probe,
  pattern = 'NvimTreeSetup',
  callback = function()
    setup_events = setup_events + 1
    order[#order + 1] = 'tree.setup'
    if setup_events == 1 then
      original_tree_setup = require('nvim-tree').setup
      original_default = require('nvim-tree.keymap').on_attach_default
    end
  end,
})
vim.api.nvim_create_autocmd('User', {
  group = probe,
  pattern = 'LazyLoad',
  callback = function(event)
    if event.data == 'nvim-tree.lua' then
      lazy_events = lazy_events + 1
      order[#order + 1] = 'LazyLoad'
    end
  end,
})

-- -u NONE/-l may disable loadplugins; the real lazy setup returns before
-- Config.setup in that mode, so explicitly enable its normal public path.
vim.go.loadplugins = true
lazy.setup({
  { dir = tree_root, name = 'nvim-tree.lua', lazy = true, opts = {} },
}, {
  local_spec = false,
  install = { missing = false },
  change_detection = { enabled = false },
  pkg = { enabled = false },
  rocks = { enabled = false },
  performance = { cache = { enabled = false } },
})
check(package.loaded['nvim-tree'] == nil, 'lazy setup eagerly loaded lazy=true nvim-tree')

require('lazy.core.loader').load('nvim-tree.lua', { start = 'nvim-zh-real-smoke' })
equal(setup_events, 1, 'real lazy config did not run tree.setup({})')
equal(lazy_events, 0, 'LazyLoad fired synchronously before tree.setup returned')
equal(order[1], 'tree.setup', 'real lazy order did not start with tree.setup')
local tree = require('nvim-tree')
local keymap = require('nvim-tree.keymap')
local config = require('nvim-tree.config')
local tree_notify = require('nvim-tree.notify')
local original_notify_warn = tree_notify.warn
equal(config.g.on_attach, 'default', 'setup({}) did not select default on_attach')
check(type(config.u) == 'table' and next(config.u) == nil, 'real setup argument was not empty options')
check(tree.setup == original_tree_setup, 'tree.setup was wrapped before real LazyLoad')
check(keymap.on_attach_default == original_default, 'default attach was wrapped before real LazyLoad')

check(vim.wait(3000, function() return lazy_events == 1 end), 'real LazyLoad was not delivered')
equal(order[2], 'LazyLoad', 'real lazy order was not setup then LazyLoad')
check(tree.setup ~= original_tree_setup, 'LazyLoad did not attach real tree setup lifecycle')
check(keymap.on_attach_default ~= original_default, 'LazyLoad did not wrap real default on_attach')
check(tree_notify.warn == original_notify_warn, 'adapter wrapped nvim-tree notify instead of registering a source')
local tree_info = zh.status().plugins['nvim-tree']
check(tree_info.active and tree_info.seam == 'keymap.on_attach_default; setup lifecycle; exact vim.notify title',
  'real nvim-tree active capability missing')
check(tree_info.existing_buffers == 'not_reattached', 'existing-buffer limitation not reported')

local original_keymap_set = vim.keymap.set
local captures = {}
local function keymap_spy(mode, lhs, rhs, opts)
  captures[#captures + 1] = { mode = mode, lhs = lhs, rhs = rhs, opts = opts }
  return original_keymap_set(mode, lhs, rhs, opts)
end
vim.keymap.set = keymap_spy

local baseline_buf = vim.api.nvim_create_buf(false, true)
original_default(baseline_buf)
local baseline = captures
captures = {}
vim.api.nvim_buf_delete(baseline_buf, { force = true })
local translated_buf = vim.api.nvim_create_buf(false, true)
keymap.on_attach_default(translated_buf)
local translated = captures
captures = {}
equal(vim.keymap.set, keymap_spy, 'real default attach leaked keymap.set wrapper')
equal(#baseline, 60, 'pinned default mapping source inventory')
equal(#translated, 60, 'translated default mapping call inventory')
local by_lhs = {}
for index, item in ipairs(expected) do
  local before, after = baseline[index], translated[index]
  equal(after.lhs, item[1], 'default lhs at source index ' .. index)
  equal(before.lhs, after.lhs, 'baseline/translated lhs differ at ' .. item[1])
  equal(before.opts.desc, 'nvim-tree: ' .. item[2], 'source description at ' .. item[1])
  equal(after.opts.desc, 'nvim-tree: ' .. item[3], 'translated description at ' .. item[1])
  check(vim.deep_equal(before.mode, after.mode), 'mapping mode changed at ' .. item[1])
  check(before.rhs == after.rhs, 'mapping rhs identity changed at ' .. item[1])
  equal(before.opts.buffer, baseline_buf, 'baseline buffer at ' .. item[1])
  equal(after.opts.buffer, translated_buf, 'translated buffer at ' .. item[1])
  check(after.opts.noremap and after.opts.silent and after.opts.nowait, 'mapping flags changed at ' .. item[1])
  check(by_lhs[item[1]] == nil, 'duplicate default lhs inventory entry: ' .. item[1])
  by_lhs[item[1]] = after
end
vim.api.nvim_buf_delete(translated_buf, { force = true })
vim.keymap.set = original_keymap_set

local api = require('nvim-tree.api')
check(by_lhs['<CR>'].rhs == api.node.open.edit and by_lhs.o.rhs == api.node.open.edit,
  'Open callbacks changed')
check(by_lhs['g?'].rhs == api.tree.toggle_help, 'Help callback changed')
check(by_lhs['<C-]>'].rhs == api.tree.change_root_to_node, 'CD callback changed')

-- The real help parser removes only the exact ASCII prefix from translated maps.
vim.o.columns = 240
vim.o.lines = 60
local help = require('nvim-tree.help')
help.toggle()
local help_lines = vim.api.nvim_buf_get_lines(help.bufnr, 0, -1, false)
local help_text = table.concat(help_lines, '\n')
check(help_text:find('帮助', 1, true) ~= nil, 'translated Help missing from real help buffer')
check(help_text:find('复制绝对路径', 1, true) ~= nil, 'translated path mapping missing from help')
check(not help_text:find('nvim-tree: ', 1, true), 'ASCII prefix was not stripped by real help parser')
help.toggle()

notifications = {}
tree_notify.warn('No bookmarks to delete.')
tree_notify.warn('Cannot create: path already exists: /tmp/a b')
tree_notify.warn('User supplied /tmp/path')
check(vim.wait(3000, function() return #notifications >= 3 end), 'real nvim-tree notifications not delivered')
equal(notifications[1].msg, '[NvimTree] 没有可删除的书签。', 'real fixed notification translation')
equal(notifications[2].msg, '[NvimTree] 无法创建：路径已存在：/tmp/a b', 'notification path placeholder changed')
equal(notifications[3].msg, '[NvimTree] User supplied /tmp/path', 'unknown notification was fuzzy translated')
for index = 1, 3 do
  equal(notifications[index].level, vim.log.levels.WARN, 'notification level at ' .. index)
  equal(notifications[index].opts.title, 'NvimTree', 'notification title at ' .. index)
end
check(tree_notify.warn == original_notify_warn, 'notification call wrapped plugin-owned notify')

local custom_calls = 0
local custom_rhs = function() end
local custom_on_attach = function(bufnr)
  custom_calls = custom_calls + 1
  vim.keymap.set('n', 'o', custom_rhs, { buffer = bufnr, desc = 'Open' })
  vim.keymap.set('n', '?', custom_rhs, { buffer = bufnr, desc = 'nvim-tree: Help' })
end
local custom_opts = { on_attach = custom_on_attach, log = { enable = false } }
local wrapped_setup = tree.setup
tree.setup(custom_opts)
check(config.u.on_attach == custom_on_attach and config.g.on_attach == custom_on_attach,
  'real custom on_attach was chained or replaced')
zh.refresh()
check(tree.setup == wrapped_setup, 'public refresh stacked real tree setup wrapper')
local custom_buf = vim.api.nvim_create_buf(false, true)
keymap.on_attach(custom_buf)
equal(custom_calls, 1, 'real custom on_attach call count')
local custom_desc = {}
for _, map in ipairs(vim.api.nvim_buf_get_keymap(custom_buf, 'n')) do
  custom_desc[map.lhs] = map.desc
end
equal(custom_desc.o, 'Open', 'custom desc colliding with default catalog was translated')
equal(custom_desc['?'], 'nvim-tree: Help', 'custom prefixed desc was translated')
vim.api.nvim_buf_delete(custom_buf, { force = true })

-- Reload real module tables, then use the public refresh boundary to adapt the
-- new generation and restore only wrappers owned by the old generation.
local old_default_wrapper = keymap.on_attach_default
local old_setup_wrapper = tree.setup
package.loaded['nvim-tree.keymap'] = nil
local next_keymap = require('nvim-tree.keymap')
local next_original_default = next_keymap.on_attach_default
package.loaded['nvim-tree'] = nil
local next_tree = require('nvim-tree')
local next_original_setup = next_tree.setup
check(next_keymap ~= keymap and next_tree ~= tree, 'real module generation did not replace tables')
zh.refresh()
check(keymap.on_attach_default ~= old_default_wrapper, 'old real keymap wrapper remains installed after generation')
check(tree.setup ~= old_setup_wrapper, 'old real tree wrapper remains installed after generation')
equal(keymap.on_attach_default, original_default, 'old real keymap generation not restored')
equal(tree.setup, original_tree_setup, 'old real tree generation not restored')
check(next_keymap.on_attach_default ~= next_original_default, 'new real keymap generation not adapted')
check(next_tree.setup ~= next_original_setup, 'new real tree generation not adapted')
check(zh.status().plugins['nvim-tree'].active, 'new real generation not active')

require('nvim-zh.plugins').teardown()
equal(next_keymap.on_attach_default, next_original_default, 'real keymap teardown failed')
equal(next_tree.setup, next_original_setup, 'real tree setup teardown failed')
check(tree_notify.warn == original_notify_warn, 'teardown changed plugin-owned notify')
cmp_info = zh.status().plugins['nvim-cmp']
check(not cmp_info.active and cmp_info.reason == 'inventory_only_no_cmp_owned_fixed_labels',
  'nvim-cmp inventory assertion changed after teardown')
print('ADDITIONAL_UPSTREAM_SMOKE_SPEC=PASS lazy=306a055 nvim-tree=69eb0c3 mappings=60 custom_desc=original notify=source_only generations=true nvim-cmp=inventory_only')
