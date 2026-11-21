local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack
local common = require('nvim-zh.adapters.common')
local adapter = require('nvim-zh.adapters.nvim_dap_ui')

local entries = {
  notification = {
    ['No such element: %s'] = '不存在元素：%s',
    ['No active debug session'] = '没有活动的调试会话',
    ['Rendering failed: %s'] = '渲染失败：%s',
    ['No source available for frame'] = '当前栈帧没有可用源码',
    ["Debug server doesn't support setting %s"] = '调试服务器不支持设置 %s',
    ['No expand action for current line'] = '当前行没有展开操作',
    ['No open action for current line'] = '当前行没有打开操作',
    ['No remove action for current line'] = '当前行没有移除操作',
    ['No edit action for current line'] = '当前行没有编辑操作',
    ['No repl action for current line'] = '当前行没有 REPL 操作',
    ['No toggle action for current line'] = '当前行没有切换操作',
    ['No watch action for current line'] = '当前行没有监视操作',
  },
  runtime = { ['No active session'] = '没有活动的调试会话' },
  empty = { ['No Expressions\n'] = '没有监视表达式\n' },
  breakpoint = {
    ['Log Message:'] = '日志消息：', ['Condition:'] = '条件：', ['Hit Condition:'] = '命中条件：',
  },
  render = { [' ... [%s more lines]'] = ' ……[还有 %s 行]' },
  source = { ['<unknown>'] = '<未知>' },
  select = { ['Select an element:'] = '选择元素：' },
  select_window = { ['Select window: '] = '选择 Window： ' },
  select_item = {
    Scopes = '作用域', Breakpoints = '断点', Stacks = '调用栈', Watches = '监视',
    Repl = 'REPL', Console = '控制台',
  },
  element_title = {
    scopes = '作用域', breakpoints = '断点', stacks = '调用栈', watches = '监视',
    repl = 'REPL', console = '控制台', hover = '悬停',
  },
  mapping = {
    expand = '展开', open = '打开', remove = '移除', edit = '编辑',
    repl = '发送到 REPL', toggle = '切换', watch = '添加到监视',
  },
}
require('nvim-zh.engine').setup({
  overrides = { ['nvim-dap-ui'] = entries },
  missing = { enabled = false, max_entries = 64 },
})

local enabled = true
local source, released = nil, false
local ctx = {
  enabled = function() return enabled end,
  verify = function() return { kind = 'fixture' } end,
  translate = common.translate,
  register_source = function(spec)
    source = spec
    released = false
    return function() released = true end
  end,
}

local names = {
  'dapui', 'dapui.config', 'dapui.util', 'dapui.windows', 'dapui.render',
  'dapui.render.canvas', 'nio.ui',
}
for _, name in ipairs(names) do package.loaded[name] = nil end
local forced = 0
for _, name in ipairs({ 'dapui', 'dapui.render.canvas', 'nio.ui' }) do
  package.preload[name] = function() forced = forced + 1; error('forced load: ' .. name) end
end
adapter.attach(ctx)
equal(forced, 0, 'adapter forced an absent module')
equal(source.title, 'nvim-dap-ui', 'notification source title')
equal(source.domain, 'nvim-dap-ui', 'notification source domain')
equal(source.context, 'notification', 'notification source context')
adapter.detach()
check(released, 'empty attach/detach did not release notification source')
for _, name in ipairs({ 'dapui', 'dapui.render.canvas', 'nio.ui' }) do package.preload[name] = nil end

-- A lifecycle wrapper alone is not display coverage.
local lifecycle_only = { setup = function() end }
package.loaded.dapui = lifecycle_only
adapter.attach(ctx)
local lifecycle_info = adapter.info(ctx)
check(not lifecycle_info.active and lifecycle_info.lifecycle_active,
  'setup-only lifecycle was reported as display active')
equal(lifecycle_info.reason, 'waiting_for_setup', 'setup-only lifecycle reason')
adapter.detach()
package.loaded.dapui = nil

local Canvas = {}
Canvas.__index = Canvas
function Canvas:write(text, opts)
  if type(text) == 'table' then
    for _, part in pairs(text) do
      if type(part) == 'table' then self:write(part[1], part) else self:write(part) end
    end
    return
  end
  self.writes[#self.writes + 1] = { text = text, opts = opts }
  return 'write-return'
end

local canvas_setup_count = 0
local function make_canvas()
  canvas_setup_count = canvas_setup_count + 1
  local module = { serial = canvas_setup_count }
  module.new = function()
    return setmetatable({ writes = {} }, Canvas), 'canvas-tail'
  end
  module.original_new = module.new
  return module
end

local mapping_calls, float_calls, select_calls = {}, {}, {}
local util = {}
util.apply_mapping = function(mappings, func, buffer, label)
  mapping_calls[#mapping_calls + 1] = { mappings = mappings, func = func, buffer = buffer, label = label }
  return label, 'mapping-tail'
end
util.format_value = function(value_start, value)
  local result = {}
  local max_lines = package.loaded['dapui.config'].render.max_value_lines
  local index = 0
  for line in vim.gsplit(value, '\n') do
    index = index + 1
    if max_lines and index > max_lines then
      local count = 1
      for _ in value:gmatch('\n') do count = count + 1 end
      result[index - 1] = result[index - 1] .. (' ... [%s more lines]'):format(count - index + 1)
      break
    end
    if index > 1 then line = string.rep(' ', value_start - 2) .. line end
    result[index] = line
  end
  return result
end
util.format_error = function(err)
  if vim.tbl_isempty(err.body or {}) then return err.message end
  if not err.body.error then return err.body.message end
  return err.body.error.format
end
local select_behavior, select_reenter = nil, false
util.select_win = function(...)
  local custom = package.loaded['dapui.config'].select_window
  if custom then return custom(...) end
  if select_behavior then return select_behavior(...) end
  _G.print('Select window: ')
  if select_reenter then
    select_reenter = false
    return util.select_win(...)
  end
  return _G.print('User ', 1, nil)
end

local windows = {}
windows.open_float = function(name, element, position, settings)
  element.buffer()
  if type(settings) == 'function' then settings = settings() end
  float_calls[#float_calls + 1] = { name = name, element = element, position = position, settings = settings }
  return settings.title, 'float-tail'
end

local nio_ui = {}
nio_ui.select = function(items, args)
  select_calls[#select_calls + 1] = { items = items, args = args }
  local labels = {}
  for _, item in ipairs(items) do labels[#labels + 1] = args.format_item(item) end
  return items[1], labels, 'select-tail'
end

local dapui = { setup_calls = 0 }
package.loaded['dapui.config'] = { render = { max_value_lines = 2 } }
package.loaded['dapui.util'] = util
package.loaded['dapui.windows'] = windows
package.loaded['nio.ui'] = nio_ui
local original_setup, original_mapping = nil, util.apply_mapping
local original_format_value, original_format_error = util.format_value, util.format_error
local original_select_window = util.select_win
local original_float, original_select = windows.open_float, nio_ui.select
local setup_opts
original_setup = function(opts)
  dapui.setup_calls = dapui.setup_calls + 1
  setup_opts = opts
  package.loaded['dapui.render.canvas'] = make_canvas()
  local canvas = package.loaded['dapui.render.canvas']
  package.loaded['dapui.render'] = { new_canvas = canvas.new }
  return 'setup-return', nil, 'setup-tail'
end
dapui.setup = original_setup
package.loaded.dapui = dapui

enabled = true
adapter.attach(ctx)
check(dapui.setup ~= original_setup, 'setup lifecycle not attached')
check(package.loaded['dapui.render.canvas'] == nil, 'canvas forced before real setup')
local pre_items = { 'scopes', 'breakpoints', 'stacks', 'watches', 'repl', 'console' }
local pre_args = {
  prompt = 'Select an element:',
  format_item = function(item) return item:sub(1, 1):upper() .. item:sub(2) end,
}
nio_ui.select(pre_items, pre_args)
check(select_calls[#select_calls].args == pre_args, 'selector translated before dapui setup')
equal(select_calls[#select_calls].args.prompt, 'Select an element:', 'pre-setup prompt')
local setup_wrapper = dapui.setup
adapter.attach(ctx)
equal(dapui.setup, setup_wrapper, 'repeated attach stacked setup')
local opts = { layouts = {}, render = { max_value_lines = 2 } }
local setup_returns = pack(dapui.setup(opts))
equal(setup_returns.n, 3, 'setup return arity')
equal(setup_returns[1], 'setup-return', 'setup first return')
equal(setup_returns[3], 'setup-tail', 'setup tail return')
check(setup_opts == opts, 'setup options identity changed')
local canvas = package.loaded['dapui.render.canvas']
local render = package.loaded['dapui.render']
local original_new = canvas.original_new
check(canvas.new ~= original_new, 'post-setup canvas not attached')
check(render.new_canvas ~= original_new, 'snapshot render alias not attached')

local instance = canvas.new()
instance:write('Log Message:', { group = 'DapUIBreakpointsInfo' })
instance:write('Condition:', { group = 'DapUIBreakpointsInfo' })
instance:write('Hit Condition:', { group = 'DapUIBreakpointsInfo' })
instance:write('No Expressions\n', { group = 'DapUIWatchesEmpty' })
instance:write('<unknown>', { group = 'DapUISource' })
instance:write('Locals', { group = 'DapUIScope' })
instance:write('Condition:', { group = 'DapUIValue' })
instance:write('/tmp/Condition:', { group = 'DapUISource' })
instance:write({ { 'Log Message:', group = 'DapUIBreakpointsInfo' }, ' raw' })
equal(instance.writes[1].text, '日志消息：', 'log label')
equal(instance.writes[2].text, '条件：', 'condition label')
equal(instance.writes[3].text, '命中条件：', 'hit condition label')
equal(instance.writes[4].text, '没有监视表达式\n', 'empty placeholder newline')
equal(instance.writes[5].text, '<未知>', 'unknown source')
equal(instance.writes[6].text, 'Locals', 'dynamic scope translated')
equal(instance.writes[7].text, 'Condition:', 'dynamic value collided with fixed label')
equal(instance.writes[8].text, '/tmp/Condition:', 'dynamic path changed')
equal(instance.writes[9].text, '日志消息：', 'nested highlight label')
equal(instance.writes[10].text, ' raw', 'nested raw suffix changed')
local raw_write = rawget(instance, 'write')
check(type(raw_write) == 'function', 'canvas instance wrapper missing')

local keys, callback = { '<CR>' }, function() return 'callback' end
local mapping_returns = pack(util.apply_mapping(keys, callback, 42, 'open'))
equal(mapping_returns[1], '打开', 'mapping desc')
equal(mapping_returns[2], 'mapping-tail', 'mapping trailing return')
local map_call = mapping_calls[#mapping_calls]
check(map_call.mappings == keys and map_call.func == callback and map_call.buffer == 42,
  'mapping behavior arguments changed')
util.apply_mapping(keys, callback, 42, nil)
equal(mapping_calls[#mapping_calls].label, nil, 'floating close acquired a new description')

local value = 'first\nsecond\nthird\nfourth'
local formatted = util.format_value(4, value)
equal(formatted[#formatted], '  second ……[还有 2 行]', 'truncation suffix or dynamic prefix')
equal(value, 'first\nsecond\nthird\nfourth', 'source value mutated')
local untruncated = 'user ... [9 more lines]'
local untruncated_lines = util.format_value(1, untruncated)
equal(untruncated_lines[1], untruncated, 'user text falsely treated as truncation')
equal(util.format_error({ message = 'No active session' }), '没有活动的调试会话', 'synthetic no-session text')
equal(util.format_error({ message = 'Debugger No active session' }), 'Debugger No active session',
  'arbitrary debugger error translated')
equal(util.format_error({ message = 'No active session', body = {} }), 'No active session',
  'DAP-bodied error borrowed the synthetic fixed translation')
local dap_error = { body = { message = 'adapter message' } }
equal(util.format_error(dap_error), 'adapter message', 'DAP body message changed')

local global_print = _G.print
local print_calls = {}
local print_spy = function(...)
  print_calls[#print_calls + 1] = pack(...)
  return 'print-return', nil, 'print-tail'
end
_G.print = print_spy
local selected_returns = pack(util.select_win('select-arg'))
equal(selected_returns.n, 3, 'select_win/print return arity')
equal(selected_returns[1], 'print-return', 'select_win first return')
equal(selected_returns[3], 'print-tail', 'select_win tail return')
equal(print_calls[#print_calls - 1][1], '选择 Window： ', 'default select window prompt')
equal(print_calls[#print_calls][1], 'User ', 'unrelated print first argument')
equal(print_calls[#print_calls][2], 1, 'unrelated print varargs')
check(_G.print == print_spy, 'select_win did not restore print')
local custom_provider = function(...) return 'custom-window', ... end
package.loaded['dapui.config'].select_window = custom_provider
local custom_returns = pack(util.select_win('custom-arg'))
equal(custom_returns[1], 'custom-window', 'custom select_window provider result')
equal(custom_returns[2], 'custom-arg', 'custom select_window provider argument')
package.loaded['dapui.config'].select_window = nil
select_behavior = function()
  _G.print('Select window: ')
  error('select-window-error')
end
local select_ok, select_err = pcall(util.select_win)
select_behavior = nil
check(not select_ok and tostring(select_err):find('select-window-error', 1, true),
  'select_win original error swallowed')
check(_G.print == print_spy, 'select_win error path did not restore print')
select_reenter = true
print_calls = {}
util.select_win()
equal(print_calls[1][1], '选择 Window： ', 'outer reentrant select prompt')
equal(print_calls[2][1], '选择 Window： ', 'inner reentrant select prompt')
check(_G.print == print_spy, 'reentrant select_win did not restore print chain')
local external_print = function() return 'external-print' end
select_behavior = function()
  _G.print('Select window: ')
  _G.print = external_print
  return 'external-select'
end
equal(util.select_win(), 'external-select', 'external select result')
select_behavior = nil
check(_G.print == external_print, 'select_win overwrote later external print')
_G.print = global_print

local default_settings = { title = 'scopes', width = 20 }
local float_buffer_calls = 0
local element = { buffer = function() float_buffer_calls = float_buffer_calls + 1; return 0 end }
local float_returns = pack(windows.open_float('scopes', element, 'position', default_settings))
equal(float_returns[1], 'scopes', 'unproven title translated')
equal(float_returns[2], 'float-tail', 'float trailing return')
equal(default_settings.title, 'scopes', 'caller settings mutated')
equal(float_calls[#float_calls].name, 'scopes', 'float internal name translated')
local custom_settings = { title = 'User Title' }
windows.open_float('scopes', element, 'position', custom_settings)
check(float_calls[#float_calls].settings == custom_settings, 'custom title settings copied')
equal(float_calls[#float_calls].settings.title, 'User Title', 'custom float title translated')
windows.open_float('watches', element, 'position', function() return { title = 'watches' } end)
equal(float_calls[#float_calls].settings.title, 'watches', 'unproven function title translated')
equal(float_buffer_calls, 3, 'float requested the element buffer more than once')

local items = { 'scopes', 'breakpoints', 'stacks', 'watches', 'repl', 'console' }
local select_args = {
  prompt = 'Select an element:',
  format_item = function(item) return item:sub(1, 1):upper() .. item:sub(2) end,
}
local select_returns = pack(nio_ui.select(items, select_args))
equal(select_returns[1], 'scopes', 'select raw return item')
equal(select_returns[2][1], '作用域', 'select built-in Scopes label')
equal(select_returns[2][2], '断点', 'select built-in Breakpoints label')
equal(select_returns[2][5], 'REPL', 'select built-in REPL label')
equal(select_returns[3], 'select-tail', 'select trailing return')
equal(select_args.prompt, 'Select an element:', 'select caller opts mutated')
local foreign_items = { 'scopes', 'custom-element' }
local foreign_args = { prompt = 'Select an element:', format_item = select_args.format_item }
nio_ui.select(foreign_items, foreign_args)
check(select_calls[#select_calls].args == foreign_args, 'custom item list reached shared selector projection')
equal(select_calls[#select_calls].args.prompt, 'Select an element:', 'custom list prompt translated')
equal(select_calls[#select_calls].args.format_item('scopes'), 'Scopes', 'custom list label translated')
local foreign_format_args = {
  prompt = 'Select an element:',
  format_item = function(item) return 'User ' .. item end,
}
nio_ui.select(items, foreign_format_args)
equal(select_calls[#select_calls].args.format_item('scopes'), 'User scopes', 'foreign formatter label translated')
local unrelated_args = { prompt = 'User prompt', format_item = select_args.format_item }
nio_ui.select(items, unrelated_args)
check(select_calls[#select_calls].args == unrelated_args, 'unrelated prompt projected')
equal(select_calls[#select_calls].args.format_item(items[1]), 'Scopes', 'unrelated selector translated')

local render_instance = render.new_canvas()
render_instance:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(render_instance.writes[1].text, '条件：', 'render alias canvas projection')
equal(common.translate('nvim-dap-ui', 'notification', 'No such element: user-element'), '不存在元素：user-element',
  'formatted element notification')
equal(common.translate('nvim-dap-ui', 'notification', "Debug server doesn't support setting foo.bar"),
  '调试服务器不支持设置 foo.bar', 'formatted debugger capability notification')

-- Repeated setup preserves wrapper identity and reattaches newly loaded leaf generations.
local owned_setup = dapui.setup
dapui.setup(opts)
equal(dapui.setup, owned_setup, 'public setup replaced owned setup wrapper')
canvas = package.loaded['dapui.render.canvas']
render = package.loaded['dapui.render']
original_new = canvas.original_new
check(canvas.new ~= original_new, 'repeated setup leaf generation not attached')

-- Disable and retained wrappers must be transparent; instance shape is restored.
enabled = false
adapter.attach(ctx)
equal(dapui.setup, original_setup, 'disable did not restore setup')
equal(util.apply_mapping, original_mapping, 'disable did not restore mapping')
equal(util.format_value, original_format_value, 'disable did not restore format_value')
equal(util.format_error, original_format_error, 'disable did not restore format_error')
equal(util.select_win, original_select_window, 'disable did not restore select_win')
equal(windows.open_float, original_float, 'disable did not restore float')
equal(nio_ui.select, original_select, 'disable did not restore select')
equal(canvas.new, original_new, 'disable did not restore canvas.new')
equal(rawget(instance, 'write'), nil, 'disable did not restore canvas instance shape')
local retained_canvas = canvas.new
local retained = retained_canvas()
retained:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(retained.writes[1].text, 'Condition:', 'retained stale canvas factory still translated')

-- A real table replacement is a generation change, including old-generation cleanup.
enabled = true
adapter.attach(ctx)
local old_canvas, old_wrapper = canvas, canvas.new
local next_canvas = make_canvas()
package.loaded['dapui.render.canvas'] = next_canvas
package.loaded['dapui.render'] = { new_canvas = next_canvas.new }
adapter.attach(ctx)
equal(old_canvas.new, original_new, 'old canvas generation not restored')
check(next_canvas.new ~= old_wrapper, 'new canvas generation not attached')
local stale = old_wrapper()
stale:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(stale.writes[1].text, 'Condition:', 'stale old-generation wrapper translated')
local current = next_canvas.new()
current:write('Condition:', { group = 'DapUIBreakpointsInfo' })
equal(current.writes[1].text, '条件：', 'new generation display text')

-- Same-generation replacement is owned by the external caller, never reclaimed.
local external_new = function() return setmetatable({ writes = {} }, Canvas) end
next_canvas.new = external_new
adapter.attach(ctx)
equal(next_canvas.new, external_new, 'refresh reclaimed external canvas.new')
equal(adapter.info(ctx).canvas.reason, 'external_override', 'external override not reported')
adapter.detach()
equal(next_canvas.new, external_new, 'teardown reclaimed external canvas.new')

local po = table.concat(vim.fn.readfile(vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/nvim-dap-ui.po'), '\n')
check(po:find('msgid "No Expressions\\n"', 1, true) ~= nil, 'PO lost placeholder newline')
check(po:find('msgid " ... [%s more lines]"', 1, true) ~= nil, 'PO lost leading truncation space')
check(po:find('msgid "Locals"', 1, true) == nil, 'PO contains debugger scope data')
print('NVIM_DAP_UI_ADAPTER_SPEC=PASS fixed_display dynamic_fallback setup generations external_override teardown')
