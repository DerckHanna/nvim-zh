local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local dap_root = assert(vim.env.NVIM_ZH_TEST_NVIM_DAP, 'NVIM_ZH_TEST_NVIM_DAP is required')
local ui_root = assert(vim.env.NVIM_ZH_TEST_NVIM_DAP_UI, 'NVIM_ZH_TEST_NVIM_DAP_UI is required')
local nio_root = assert(vim.env.NVIM_ZH_TEST_NVIM_NIO, 'NVIM_ZH_TEST_NVIM_NIO is required')
vim.opt.runtimepath:prepend(nio_root)
vim.opt.runtimepath:prepend(dap_root)
vim.opt.runtimepath:prepend(ui_root)
vim.o.swapfile = false

-- Load the real PO directly: this spec needs neither generated catalogs nor a
-- shared register_catalog call. All runtime entries in this PO are single-line.
local overrides = {}
local context, msgid, msgstr
local function unquote(value)
  value = value:gsub('\\\\', '\\')
  value = value:gsub('\\n', '\n')
  value = value:gsub('\\"', '"')
  return value
end
local function flush()
  if msgid and msgid ~= '' then
    assert(context and msgstr ~= nil, 'incomplete test PO entry')
    overrides[context] = overrides[context] or {}
    overrides[context][msgid] = msgstr
  end
  context, msgid, msgstr = nil, nil, nil
end
for _, line in ipairs(vim.fn.readfile(vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/nvim-dap-ui.po')) do
  local value = line:match('^msgctxt "(.*)"$')
  if value then
    if msgid then flush() end
    context = unquote(value)
  else
    value = line:match('^msgid "(.*)"$')
    if value then
      if msgid then flush() end
      msgid = unquote(value)
    else
      value = line:match('^msgstr "(.*)"$')
      if value then msgstr = unquote(value) end
    end
  end
end
flush()
local catalog_count = 0
for _, values in pairs(overrides) do for _ in pairs(values) do catalog_count = catalog_count + 1 end end
equal(catalog_count, 41, 'real PO safe entry inventory')
require('nvim-zh.engine').setup({
  overrides = { ['nvim-dap-ui'] = overrides },
  missing = { enabled = false, max_entries = 64 },
})

local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end
local select_calls = {}
vim.ui.select = function(items, opts, on_choice)
  local labels = {}
  local selected, selected_index
  for index, item in ipairs(items) do
    labels[item] = opts.format_item(item)
    if item == 'scopes' then selected, selected_index = item, index end
  end
  select_calls[#select_calls + 1] = {
    items = items, opts = opts, labels = labels, selected = selected, selected_index = selected_index,
  }
  on_choice(selected or items[1], selected_index or 1)
end

local adapter = require('nvim-zh.adapters.nvim_dap_ui')
local path = ui_root .. '/lua/dapui/init.lua'
local bytes = require('nvim-zh.fs').read(path, 1024 * 1024)
package.preload.dapui = adapter.project_source('dapui', bytes, path, function() return package.loaded.dapui ~= nil end)
local dapui = require('dapui')
package.preload.dapui = nil
local dap = require('dap')
local util = require('dapui.util')
local windows = require('dapui.windows')
local nio_ui = require('nio.ui')
check(package.loaded['nio.ui'] == nio_ui, 'nio.ui not loaded before first dapui query')
check(package.loaded['dapui.render.canvas'] == nil, 'test expected lazy render.canvas loading')
local original_setup = dapui.setup
local original_mapping = util.apply_mapping
local original_format_value = util.format_value
local original_format_error = util.format_error
local original_open_float = windows.open_float
local original_select = nio_ui.select

local config = {
  controls = { enabled = false },
  layouts = {
    {
      elements = { { id = 'watches', size = 0.5 }, { id = 'breakpoints', size = 0.5 } },
      size = 36,
      position = 'left',
    },
  },
  render = { max_value_lines = 2 },
}

local function map_snapshot(buffer)
  local result = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buffer, 'n')) do
    result[#result + 1] = {
      lhs = map.lhs, mode = map.mode, rhs = map.rhs, noremap = map.noremap,
      nowait = map.nowait, silent = map.silent, desc = map.desc,
    }
  end
  table.sort(result, function(a, b) return a.lhs < b.lhs end)
  return result
end

-- Real unadapted baseline: line shape, mapping keys/flags and Buffer identity.
dapui.setup(config)
local baseline_buffer = dapui.elements.watches.buffer()
dapui.elements.watches.render()
local baseline_lines = vim.api.nvim_buf_get_lines(baseline_buffer, 0, -1, false)
local baseline_maps = map_snapshot(baseline_buffer)
equal(table.concat(baseline_lines, '\n'), 'No Expressions\n> ', 'baseline empty watches text and prompt')
equal(vim.api.nvim_buf_get_name(baseline_buffer):match('DAP Watches$'), 'DAP Watches',
  'baseline Buffer identity')

local common = require('nvim-zh.adapters.common')
local enabled = true
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'source_contract' } end,
  translate = common.translate,
  register_source = function(spec) return require('nvim-zh.ui').register_source(spec) end,
}
require('nvim-zh.ui').setup({ notify = true, prompts = false, select_items = false, echo = false })
adapter.attach(ctx)
check(dapui.setup ~= original_setup, 'real setup lifecycle not attached')
check(util.apply_mapping ~= original_mapping, 'real mapping seam not attached')
check(windows.open_float ~= original_open_float, 'real float seam not attached')
check(nio_ui.select ~= original_select, 'real nio.ui select seam not attached')
check(require('nvim-zh.adapters.index')['nvim-dap-ui'].targets.baseline.commit, 'target manifest missing')

-- setup resets configuration and recreates elements; the owned wrapper must
-- survive and the first real open must already render Chinese.
local owned_setup = dapui.setup
dapui.setup(config)
equal(dapui.setup, owned_setup, 'real setup replaced its wrapper')
dapui.open()
local watches_buffer = dapui.elements.watches.buffer()
check(vim.wait(5000, function()
  local lines = vim.api.nvim_buf_get_lines(watches_buffer, 0, -1, false)
  return table.concat(lines, '\n'):find('没有监视表达式', 1, true) ~= nil
end, 10), 'first real open did not render Chinese watches placeholder')
local translated_lines = vim.api.nvim_buf_get_lines(watches_buffer, 0, -1, false)
equal(#translated_lines, #baseline_lines, 'translated real Buffer line count changed')
equal(vim.api.nvim_buf_get_name(watches_buffer):match('DAP Watches$'), 'DAP Watches',
  'adapter translated Buffer identity')
local translated_maps = map_snapshot(watches_buffer)
equal(#translated_maps, #baseline_maps, 'real mapping count changed')
local seen_desc = {}
for index, before in ipairs(baseline_maps) do
  local after = translated_maps[index]
  equal(after.lhs, before.lhs, 'real mapping lhs changed')
  equal(after.mode, before.mode, 'real mapping mode changed')
  equal(after.rhs, before.rhs, 'real mapping rhs changed')
  equal(after.noremap, before.noremap, 'real mapping noremap changed')
  equal(after.nowait, before.nowait, 'real mapping nowait changed')
  equal(after.silent, before.silent, 'real mapping silent changed')
  if after.desc then seen_desc[after.desc] = true end
end
check(seen_desc['打开'] and seen_desc['编辑'] and seen_desc['发送到 REPL'],
  'real Chinese mapping descriptions missing')
local raw_config = require('dapui.config')
equal(raw_config.layouts[1].elements[1].id, 'watches', 'layout element ID translated')
equal(raw_config.controls.element, 'repl', 'controls internal element ID translated')
equal(raw_config.mappings.open[1], 'o', 'mapping action configuration changed')

local namespace = require('dapui.render.canvas').namespace
local marks = vim.api.nvim_buf_get_extmarks(watches_buffer, namespace, 0, -1, { details = true })
local empty_mark
for _, mark in ipairs(marks) do
  if mark[4].hl_group == 'DapUIWatchesEmpty' then empty_mark = mark end
end
check(empty_mark ~= nil, 'real empty highlight missing')
equal(empty_mark[4].end_col, #'没有监视表达式', 'Chinese highlight byte width')
local real_canvas = require('dapui.render.canvas').new()
real_canvas:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(real_canvas:line_width(), #'条件：', 'Canvas line width not based on projected bytes')

-- Fixed synthetic state is translated, while the expression itself is user data.
dapui.elements.watches.add('user_expr')
dapui.elements.watches.render()
local watches_text = table.concat(vim.api.nvim_buf_get_lines(watches_buffer, 0, -1, false), '\n')
check(watches_text:find('user_expr: 没有活动的调试会话', 1, true) ~= nil,
  'real no-session watch or expression projection')
dapui.elements.watches.remove(1)
dapui.elements.watches.render()

-- Real nvim-dap breakpoints supply all three fixed labels and dynamic payloads.
local source_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source_buffer, 'nvim-zh-dap-ui-dynamic.lua')
vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { 'local dynamic_value = 1', 'return dynamic_value' })
require('dap.breakpoints').set({
  condition = 'x > 1', hit_condition = '2', log_message = 'hello {x}',
}, source_buffer, 1)
dapui.elements.breakpoints.render()
local breakpoint_buffer = dapui.elements.breakpoints.buffer()
local breakpoint_text = table.concat(vim.api.nvim_buf_get_lines(breakpoint_buffer, 0, -1, false), '\n')
check(breakpoint_text:find('日志消息： hello {x}', 1, true) ~= nil, 'real log message label/value')
check(breakpoint_text:find('条件： x > 1', 1, true) ~= nil, 'real condition label/value')
check(breakpoint_text:find('命中条件： 2', 1, true) ~= nil, 'real hit condition label/value')
check(breakpoint_text:find('local dynamic_value = 1', 1, true) ~= nil, 'source line data changed')
check(breakpoint_text:find('nvim%-zh%-dap%-ui%-dynamic%.lua') ~= nil, 'source path data changed')

-- Exercise the real float window API while capturing its final display settings.
local float_module = require('dapui.windows.float')
local original_float_open = float_module.open_float
local captured_float, captured_win
float_module.open_float = function(settings)
  captured_float = settings
  local result = original_float_open(settings)
  captured_win = result.win_id
  return result
end
dapui.float_element('watches', { width = 50, height = 4, enter = false })
check(vim.wait(5000, function() return captured_float ~= nil end, 10), 'real float did not open')
equal(captured_float.title, '监视', 'real default float title')
local win_title = vim.api.nvim_win_get_config(captured_win).title
if type(win_title) == 'table' then
  local parts = {}
  for _, part in ipairs(win_title) do parts[#parts + 1] = type(part) == 'table' and part[1] or tostring(part) end
  win_title = table.concat(parts)
end
equal(win_title, '监视', 'real nvim_win_get_config title')
windows.close_float('watches')
captured_float = nil
dapui.float_element('watches', { title = 'watches', width = 50, height = 4, enter = false })
check(vim.wait(5000, function() return captured_float ~= nil end, 10), 'user-titled float did not open')
equal(captured_float.title, 'watches', 'same-text user title translated')
windows.close_float('watches')
float_module.open_float = original_float_open

-- The shared nio selector is reached by the actual no-argument public call.
local select_before = #select_calls
notifications = {}
dapui.float_element()
check(vim.wait(5000, function() return #select_calls > select_before end, 10), 'real element query did not run')
local selected = select_calls[#select_calls]
equal(selected.opts.prompt, '选择元素：', 'real select prompt')
equal(selected.labels.scopes, '作用域', 'real select Scopes')
equal(selected.labels.breakpoints, '断点', 'real select Breakpoints')
equal(selected.labels.stacks, '调用栈', 'real select Stacks')
equal(selected.labels.watches, '监视', 'real select Watches')
equal(selected.labels.repl, 'REPL', 'real select REPL')
equal(selected.labels.console, '控制台', 'real select Console')
equal(selected.selected, 'scopes', 'selector returned translated ID')
check(vim.wait(5000, function()
  return #notifications > 0 and notifications[#notifications].msg == '没有活动的调试会话'
end, 10), 'real notification source route')
equal(notifications[#notifications].opts.title, 'nvim-dap-ui', 'notification title changed')
equal(notifications[#notifications].level, vim.log.levels.WARN, 'notification level changed')

-- A real missing element retains its dynamic raw ID in the fixed template.
notifications = {}
dapui.float_element('missing-element')
check(vim.wait(5000, function() return #notifications > 0 end, 10), 'missing element notification missing')
equal(notifications[#notifications].msg, '不存在元素：missing-element', 'missing element template')
notifications = {}
util.notify('Debugger user output', vim.log.levels.INFO)
check(vim.wait(5000, function() return #notifications > 0 end, 10), 'dynamic notification missing')
equal(notifications[#notifications].msg, 'Debugger user output', 'dynamic debugger output translated')

-- Trigger a real installed mapping callback on the empty placeholder line.
dapui.elements.watches.render()
local watches_win = vim.fn.bufwinid(watches_buffer)
check(watches_win ~= -1, 'watches window missing')
vim.api.nvim_set_current_win(watches_win)
vim.api.nvim_win_set_cursor(watches_win, { 1, 0 })
local open_mapping
for _, map in ipairs(vim.api.nvim_buf_get_keymap(watches_buffer, 'n')) do
  if map.lhs == 'o' then open_mapping = map end
end
check(open_mapping and type(open_mapping.callback) == 'function', 'real open mapping callback missing')
notifications = {}
open_mapping.callback()
check(vim.wait(5000, function() return #notifications > 0 end, 10), 'no-action notification missing')
equal(notifications[#notifications].msg, '当前行没有打开操作', 'no-action exact action text')

-- Pure formatter differential: only the known suffix changes, never user lines.
local formatted = util.format_value(4, 'first\nsecond\nthird\nfourth')
equal(formatted[#formatted], '  second ……[还有 2 行]', 'real truncation projection')
local unchanged = 'user ... [9 more lines]'
equal(util.format_value(1, unchanged)[1], unchanged, 'real user truncation-like value changed')

-- Real two-window default selector: queued 'a' chooses A without blocking.
-- Stay in the current tab: headless Neovim's tabline click-def assertion is not
-- part of this adapter contract, and two normal splits exercise the same path.
local normal_window
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local buffer = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_win_get_config(win).relative == ''
    and vim.api.nvim_buf_get_option(buffer, 'buftype') == '' then
    normal_window = win
    break
  end
end
check(normal_window ~= nil, 'normal source window for select fixture missing')
vim.api.nvim_set_current_win(normal_window)
vim.cmd('vsplit')
local extra_window = vim.api.nvim_get_current_win()
local normal_count = 0
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local buffer = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_win_get_config(win).relative == ''
    and vim.api.nvim_buf_get_option(buffer, 'buftype') == '' then
    normal_count = normal_count + 1
  end
end
equal(normal_count, 2, 'real select window fixture')
local global_print = _G.print
local printed = {}
local print_spy = function(...)
  printed[#printed + 1] = { ... }
  return 'print-return', nil, 'print-tail'
end
_G.print = print_spy
vim.api.nvim_input('a')
local selected_window = util.select_win()
check(selected_window and vim.api.nvim_win_is_valid(selected_window), 'real select_win did not select window A')
equal(printed[1][1], '选择 Window： ', 'real select window prompt')
check(_G.print == print_spy, 'real select_win did not restore print')
_G.print = global_print
if vim.api.nvim_win_is_valid(extra_window) then vim.api.nvim_win_close(extra_window, true) end

-- Module generation on real source tables; retained old wrappers must go stale.
dapui.close()
local old_canvas = require('dapui.render.canvas')
local old_canvas_wrapper = old_canvas.new
package.loaded['dapui.render.canvas'] = nil
local new_canvas = require('dapui.render.canvas')
local new_canvas_original = new_canvas.new
package.loaded['dapui.render'] = nil
local new_render = require('dapui.render')
adapter.attach(ctx)
check(old_canvas.new ~= old_canvas_wrapper, 'real old canvas wrapper not restored')
check(new_canvas.new ~= new_canvas_original, 'real new canvas generation not attached')
local stale_canvas = old_canvas_wrapper()
stale_canvas:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(stale_canvas.lines[1], 'Condition:', 'real retained old wrapper remained active')
local current_canvas = new_canvas.new()
current_canvas:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(current_canvas.lines[1], '条件：', 'real new canvas display')

local old_util = util
package.loaded['dapui.util'] = nil
local new_util = require('dapui.util')
local new_util_original = new_util.apply_mapping
adapter.attach(ctx)
equal(old_util.apply_mapping, original_mapping, 'real old util generation not restored')
check(new_util.apply_mapping ~= new_util_original, 'real new util generation not attached')

local external_canvas_new = function() return 'external-canvas' end
new_canvas.new = external_canvas_new
adapter.attach(ctx)
equal(new_canvas.new, external_canvas_new, 'real external canvas replacement reclaimed')
equal(adapter.info(ctx).canvas.reason, 'external_override', 'real external override not reported')

adapter.detach()
equal(dapui.setup, original_setup, 'real setup teardown')
equal(old_util.apply_mapping, original_mapping, 'real old util teardown')
equal(new_util.apply_mapping, new_util_original, 'real new util teardown')
equal(new_canvas.new, external_canvas_new, 'real teardown overwrote external canvas')
local stale_after_teardown = old_canvas_wrapper()
stale_after_teardown:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(stale_after_teardown.lines[1], 'Condition:', 'real stale wrapper after teardown translated')
for _, route in ipairs(require('nvim-zh.ui').info().sources) do
  check(route.title ~= 'nvim-dap-ui', 'notification source remained after teardown')
end
require('nvim-zh.ui').teardown()
print('NVIM_DAP_UI_UPSTREAM_SPEC=PASS commit=cc9dd33 first_open real_buffer highlights mappings float select select_window notify differential generations teardown entries=41')
