local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.adapters.nvim_dap')

local names = {
  'dap', 'dap.ui', 'dap.repl', 'dap.breakpoints', 'dap.health', 'dap.entity',
  'dap.progress', 'dap.session', 'dap.utils', 'dap.ext.vscode', 'dap.ui.widgets',
}
for _, name in ipairs(names) do package.loaded[name] = nil end

local catalog = {
  prompt = {
    ['Configuration: '] = '配置： ',
    ['Exception breakpoint filters: '] = '异常断点筛选器： ',
    ['Actions> '] = '操作> ',
  },
  action = { Expand = '展开', ['Terminate session'] = '终止会话' },
  process = {},
  repl_help = { ['Commands:'] = '命令：', ['Custom commands:'] = '自定义命令：' },
  repl_hint = { ['(press enter on line to jump to frame)'] = '（在行上按 Enter 跳转到帧）' },
  mapping = {},
  quickfix = {
    Rejected = '已拒绝',
  },
  health = {
    ['dap: Adapters'] = 'dap：适配器',
    ['dap: Sessions'] = 'dap：会话',
    ['No active sessions'] = '没有活动会话',
  },
  widget = {
    Threads = '线程',
    ['No active session'] = '没有活动会话',
    ['Stopped thread has no frames'] = '已停止的线程没有栈帧',
    ["Stopped thread (%d) not found. Can't display frames"] = '未找到已停止的线程（%d）。无法显示栈帧',
    ["Error evaluating '%s':"] = "求值 '%s' 时出错：",
  },
  repl_message = { ['No active debug session'] = '没有活动的调试会话' },
  deprecation = {
    ['dap.utils.to_dict is deprecated for removal in nvim-dap 0.10.0'] = 'dap.utils.to_dict 已弃用，将在 nvim-dap 0.10.0 中移除',
    ['dap.ext.vscode.load_launchjs is deprecated as it is no longer needed.'
      .. ' ./.vscode/launch.json files are read automatically on-demand. See :help dap-providers'] =
      'dap.ext.vscode.load_launchjs 已弃用，不再需要。./.vscode/launch.json 文件会按需自动读取。参见 :help dap-providers',
  },
  session = { ['Could not resolve %s'] = '无法解析 %s' },
  diagnostic = {
    ['Thread stopped due to exception of type %s (%s)'] = '线程因类型 %s 的异常而停止（%s）',
    ['Stack trace:'] = '栈跟踪：',
  },
}
local function translate(domain, context, text)
  equal(domain, 'nvim-dap', 'translation domain')
  if type(text) ~= 'string' then return text end
  local exact = (catalog[context] or {})[text]
  if exact then return exact end
  if context == 'widget' then
    local n = text:match("^Stopped thread %((%d+)%) not found%. Can't display frames$")
    if n then return '未找到已停止的线程（' .. n .. '）。无法显示栈帧' end
    local expr = text:match("^Error evaluating '(.*)':$")
    if expr then return "求值 '" .. expr .. "' 时出错：" end
  elseif context == 'session' then
    local host = text:match('^Could not resolve (.*)$')
    if host then return '无法解析 ' .. host end
  elseif context == 'notification' then
    local cmd, adapter_name, detail = text:match('^Error running `(.-)` of `(.-)`: (.*)$')
    if cmd then return '运行 `' .. cmd .. '`（所属 `' .. adapter_name .. '`）时出错： ' .. detail end
  elseif context == 'diagnostic' then
    local kind, mode = text:match('^Thread stopped due to exception of type (.*) %((.*)%)$')
    if kind then return '线程因类型 ' .. kind .. ' 的异常而停止（' .. mode .. '）' end
  end
  if context == 'prompt' then
    local name = text:match('^New `(.-)` value: $')
    if name then return '`' .. name .. '` 的新值： ' end
    name = text:match('^New `(.-)` expression: $')
    if name then return '`' .. name .. '` 的新表达式： ' end
  elseif context == 'process' then
    local pid, name = text:match('^id=(%d+) name=(.*)$')
    if pid then return 'id=' .. pid .. '，名称=' .. name end
  elseif context == 'quickfix' then
    local value = text:match('^Rejected: (.*)$')
    if value then return '已拒绝：' .. value end
    value = text:match('^Log message: (.*)$')
    if value then return '日志消息：' .. value end
    value = text:match('^Condition: (.*)$')
    if value then return '条件：' .. value end
    value = text:match('^Hit condition: (.*)$')
    if value then return '命中条件：' .. value end
  elseif context == 'health' then
    local name = text:match('^dap%.adapter: (.*)$')
    if name then return 'dap.adapter：' .. name end
    local kind = text:match('^(.*) must be one of: executable, server or pipe$')
    if kind then return kind .. ' 必须是以下值之一：executable、server 或 pipe' end
  end
  return text
end

local enabled = true
local registered, released = 0, 0
local verified_surfaces = true
local ctx = {
  enabled = function() return enabled end,
  verify = function(surface)
    if not verified_surfaces then return nil, 'unsupported_revision' end
    return { kind = 'fixture' }
  end,
  translate = translate,
  register_source = function(spec)
    equal(spec.title, 'DAP', 'notification title')
    equal(spec.domain, 'nvim-dap', 'notification domain')
    equal(spec.context, 'notification', 'notification context')
    registered = registered + 1
    return function() released = released + 1 end
  end,
}

adapter.attach(ctx)
equal(registered, 1, 'source registration without loaded modules')
equal(adapter.info(ctx).reason, 'not_loaded', 'empty modules should stay not_loaded')
for _, name in ipairs(names) do
  equal(package.loaded[name], nil, 'attach forced module load: ' .. name)
end

local ui = {}
local captured
function ui.pick_one(items, prompt, label_fn, callback)
  captured = { items = items, prompt = prompt, label_fn = label_fn, callback = callback }
  return callback(items[1])
end
function ui.pick_one_sync(items, prompt, label_fn)
  return prompt, label_fn(items[1])
end
local original_sync = ui.pick_one_sync
package.loaded['dap.ui'] = ui

local repl = { commands = { help = { '.help', 'help', '.h' } }, lines = {} }
function repl.append(line)
  repl.lines[#repl.lines + 1] = line
  return 17
end
function repl.execute(text)
  repl.append('dap> ' .. text)
  if text == '.help' then
    repl.append('Commands:')
    repl.append('  .continue, .c')
    repl.append('Custom commands:')
  end
  return 'execute-result'
end
local open_opts = { desc = 'User mapping', silent = true }
local open_rhs = function() end
function repl.open()
  vim.keymap.set('n', '<Plug>(user-mapping)', open_rhs, open_opts)
  return 'open-result'
end
function repl.toggle() return 'toggle-result' end
function repl.print_stackframes()
  repl.append('(press enter on line to jump to frame)')
end
package.loaded['dap.repl'] = repl

local breakpoints = {}
function breakpoints.to_qf_list(items)
  local bufnr, buf_breakpoints = next(items)
  if #buf_breakpoints > 1 then
    return {
      { bufnr = bufnr, lnum = 1, text = 'first raw' },
      { bufnr = bufnr, lnum = 1, text = 'second raw' },
    }
  end
  return { { bufnr = bufnr, lnum = 1, text = 'raw' } }
end
package.loaded['dap.breakpoints'] = breakpoints

local health = {}
function health.check() end
package.loaded['dap.health'] = health

local session = {}
function session.set_exception_breakpoints(self, filters)
  local value = vim.fn.input('Exception breakpoint filters: ', 'uncaught')
  return value, self, filters
end
local original_exception = session.set_exception_breakpoints
package.loaded['dap.session'] = session

local raw_actions
local entity = { threads = { tree_spec = {} }, variable = { tree_spec = {} } }
function entity.threads.tree_spec.render_parent(thread) return thread.name end
function entity.variable.tree_spec.compute_actions()
  raw_actions = {
    { label = 'Set variable', fn = function(...)
      local args = { ... }
      local known = { vim.fn.input('New `x` value: ', 'default', args[1]) }
      local unknown = { vim.fn.input('User prompt', 'fallback', args[2]) }
      return 'action-return', known, unknown, ...
    end },
    { label = 'Set expression', fn = function()
      vim.fn.input('New `x` expression: ', 'old')
      error('action-failure', 0)
    end },
    { label = 'User action', fn = function() return 'user' end },
  }
  return raw_actions
end
local original_compute_actions = entity.variable.tree_spec.compute_actions
package.loaded['dap.entity'] = entity

adapter.attach(ctx)
adapter.attach(ctx)
equal(registered, 1, 'repeated attach duplicated notification source')
local owned_pick = ui.pick_one
local owned_sync = ui.pick_one_sync
check(owned_pick ~= nil and owned_sync ~= nil, 'UI wrappers missing')

local chosen = {}
local config = { name = 'User configuration' }
ui.pick_one({ config }, 'Configuration: ', function(item) return item.name end, function(item)
  chosen[#chosen + 1] = item
end)
equal(captured.prompt, '配置： ', 'picker prompt projection')
equal(captured.label_fn(config), 'User configuration', 'dynamic configuration name translated')
check(chosen[1] == config, 'picker changed selected item identity')

local action = { label = 'Expand', fn = function() end }
ui.pick_one({ action }, 'Actions> ', function(item) return item.label end, function() end)
equal(captured.label_fn(action), '展开', 'structurally identified action label')
local retained_action_label = captured.label_fn
local dap_target = { id = 9, label = 'Expand' }
equal(captured.label_fn(dap_target), 'Expand', 'DAP target label was translated')
local process = { pid = 42, name = 'python,worker' }
ui.pick_one({ process }, 'Select process: ', function(item)
  return ('id=%d name=%s'):format(item.pid, item.name)
end, function() end)
equal(captured.label_fn(process), 'id=42，名称=python,worker', 'default process label')

local old_input = vim.fn.input
local input_calls = {}
vim.fn.input = function(prompt, default, extra)
  input_calls[#input_calls + 1] = { prompt = prompt, default = default, extra = extra }
  return 'typed-value'
end
local input_spy = vim.fn.input
local projected_actions = entity.variable.tree_spec.compute_actions()
check(projected_actions[1] ~= raw_actions[1], 'Set variable action table was mutated in place')
equal(projected_actions[1].label, 'Set variable', 'raw action label changed')
check(projected_actions[1].fn ~= raw_actions[1].fn, 'Set variable input seam missing')
check(projected_actions[3] == raw_actions[3], 'unknown action identity changed')
local marker1, marker2 = {}, {}
local action_returns = { projected_actions[1].fn(marker1, marker2) }
equal(action_returns[1], 'action-return', 'action return value changed')
equal(action_returns[2][1], 'typed-value', 'known input result changed')
equal(action_returns[3][1], 'typed-value', 'unknown input result changed')
check(action_returns[4] == marker1 and action_returns[5] == marker2, 'action args changed')
equal(input_calls[1].prompt, '`x` 的新值： ', 'Set variable prompt')
equal(input_calls[1].default, 'default', 'Set variable input default changed')
check(input_calls[1].extra == marker1, 'known input extra arg changed')
equal(input_calls[2].prompt, 'User prompt', 'unknown input prompt translated')
equal(input_calls[2].default, 'fallback', 'unknown input default changed')
check(input_calls[2].extra == marker2, 'unknown input extra arg changed')
local ok_action, action_error = pcall(projected_actions[2].fn)
equal(ok_action, false, 'action error was swallowed')
equal(action_error, 'action-failure', 'action error value changed')
check(vim.fn.input == input_spy, 'input wrapper leaked after action error')
local retained_set_variable = projected_actions[1].fn
local exception_result, exception_self = session.set_exception_breakpoints(session, nil)
equal(exception_result, 'typed-value', 'exception input result changed')
check(exception_self == session, 'exception Session self changed')
equal(input_calls[#input_calls].prompt, '异常断点筛选器： ', 'exception filter prompt')
equal(input_calls[#input_calls].default, 'uncaught', 'exception input default changed')
check(vim.fn.input == input_spy, 'input wrapper leaked after Session call')
vim.fn.input = old_input

local old_keymap_set = vim.keymap.set
local keymap_call
vim.keymap.set = function(mode, lhs, rhs, opts)
  keymap_call = { mode = mode, lhs = lhs, rhs = rhs, opts = opts }
end
local keymap_spy = vim.keymap.set
equal(repl.open(), 'open-result', 'REPL open return changed')
check(keymap_call.opts == open_opts, 'unknown keymap desc copied opts')
check(keymap_call.rhs == open_rhs, 'unknown keymap rhs changed')
check(vim.keymap.set == keymap_spy, 'keymap wrapper leaked after REPL open')
vim.keymap.set = old_keymap_set

repl.append('Commands:')
equal(repl.lines[#repl.lines], 'Commands:', 'unscoped debugger output translated')
equal(repl.execute('.help'), 'execute-result', 'execute return value changed')
local expected_repl = { 'dap> .help', '命令：', '  .continue, .c', '自定义命令：' }
for index, expected in ipairs(expected_repl) do
  equal(repl.lines[index + 1], expected, 'REPL help line ' .. index)
end
repl.append('Commands:')
equal(repl.lines[#repl.lines], 'Commands:', 'help translation leaked after execute returned')
repl.print_stackframes()
equal(repl.lines[#repl.lines], '（在行上按 Enter 跳转到帧）', 'stack hint projection')

local root = { id = 0, name = 'Threads', threads = { { id = 2, name = 'worker' } } }
equal(entity.threads.tree_spec.render_parent(root), '线程', 'synthetic thread root')
equal(entity.threads.tree_spec.render_parent({ id = 2, name = 'Threads' }), 'Threads',
  'DAP thread with the same name was translated')

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local x = "a,b"' })
local input = {
  [buf] = {
    {
      line = 1,
      logMessage = 'x, Condition: user-data',
      condition = 'a,b',
      hitCondition = '2',
      state = { verified = false, message = 'adapter, raw' },
    },
  },
}
local original_input = vim.deepcopy(input)
local qf = breakpoints.to_qf_list(input)
check(vim.deep_equal(input, original_input), 'quickfix projection mutated breakpoint data')
equal(qf[1].text,
  'local x = "a,b", 已拒绝：adapter, raw, 日志消息：x, Condition: user-data, 条件：a,b, 命中条件：2',
  'quickfix raw-field projection or comma preservation')
input[buf][2] = { line = 1, condition = 'must-not-leak-to-first' }
local duplicate_qf = breakpoints.to_qf_list(input)
equal(duplicate_qf[1].text, 'first raw', 'ambiguous quickfix location changed first item')
equal(duplicate_qf[2].text, 'second raw', 'ambiguous quickfix location changed second item')
input[buf][2] = nil

local health_messages = {}
local old_health = vim.health
vim.health = {
  start = function(msg) health_messages[#health_messages + 1] = msg end,
  ok = function(msg) health_messages[#health_messages + 1] = msg end,
  error = function(msg) health_messages[#health_messages + 1] = msg end,
}
package.loaded['dap'] = {
  adapters = { bad = { type = 'invalid' } },
  sessions = function() return {} end,
}
function health.check()
  vim.health.start('dap: Adapters')
  vim.health.start('dap.adapter: bad')
  vim.health.error('invalid must be one of: executable, server or pipe')
  vim.health.start('dap: Sessions')
  vim.health.ok('No active sessions')
end
-- Re-sync a genuinely new owner-table generation after replacing its method.
local new_health = { check = health.check }
package.loaded['dap.health'] = new_health
adapter.attach(ctx)
local health_before_call = vim.health
new_health.check()
equal(vim.health, health_before_call, 'health proxy leaked')
local expected_health = {
  'dap：适配器', 'dap.adapter：bad',
  'invalid 必须是以下值之一：executable、server 或 pipe',
  'dap：会话', '没有活动会话',
}
for index, expected in ipairs(expected_health) do
  equal(health_messages[index], expected, 'health line ' .. index)
end
vim.health = old_health

-- Same-generation replacement belongs to the caller and is never reclaimed.
local external = function() return 'external' end
ui.pick_one = external
adapter.attach(ctx)
equal(ui.pick_one, external, 'external picker override reclaimed')
equal(adapter.info(ctx).slots.pick_one.reason, 'external_override', 'external override not reported')

-- A real owner-table generation change restores untouched old slots and wraps the new one.
local new_ui = {}
function new_ui.pick_one() return 'new-original' end
function new_ui.pick_one_sync() return 'new-sync-original' end
local new_original_pick, new_original_sync = new_ui.pick_one, new_ui.pick_one_sync
package.loaded['dap.ui'] = new_ui
adapter.attach(ctx)
check(new_ui.pick_one ~= new_original_pick and new_ui.pick_one_sync ~= new_original_sync,
  'new UI generation not attached')
equal(ui.pick_one_sync, original_sync, 'untouched old UI generation was not restored')
equal(adapter.info(ctx).slots.pick_one.active, true, 'new picker wrapper inactive')
equal(retained_action_label(action), 'Expand', 'retained label translated after module generation')

adapter.detach()
equal(retained_action_label(action), 'Expand', 'retained label translated after teardown')
equal(released, 1, 'notification source release count')
input_calls = {}
vim.fn.input = input_spy
retained_set_variable(marker1, marker2)
equal(input_calls[1].prompt, 'New `x` value: ', 'retained action translated after teardown')
equal(input_calls[2].prompt, 'User prompt', 'retained unknown prompt changed after teardown')
vim.fn.input = old_input
equal(session.set_exception_breakpoints, original_exception, 'Session input teardown failed')
equal(entity.variable.tree_spec.compute_actions, original_compute_actions, 'variable actions teardown failed')
equal(ui.pick_one, external, 'teardown reclaimed external override')
equal(repl.execute('.help'), 'execute-result', 'detached execute behavior changed')
equal(repl.lines[#repl.lines], 'Custom commands:', 'teardown left REPL translation active')
equal(adapter.info(ctx).active, false, 'adapter active after teardown')
check(package.loaded['dap.ui'] == new_ui, 'teardown changed loaded module generation')

-- ---------------------------------------------------------------------------
-- Versioned seams. The offline fixture substitutes a stub ctx.verify, so these
-- assertions cover ownership, projection precision and teardown; the pinned
-- digests and the real call sites are exercised by the upstream/TUI suites.
-- ---------------------------------------------------------------------------
local captured_widget_lines = {}
local fake_session
local widgets_module = {}
function widgets_module.builder(widget)
  local builder = {}
  local nbuf = widget.new_buf
  function builder.new_buf(value) nbuf = value return builder end
  function builder.new_win() assert(false, 'fixture builder needs no window') end
  function builder.build()
    local view = { buf = nil, win = nil, refresh = function() end, close = function() end }
    view.layer = function()
      local layer = { render = function(xs, render_fn, ctx, start, end_)
        local text = render_fn and render_fn(xs[1]) or tostring(xs[1])
        captured_widget_lines[#captured_widget_lines + 1] = text
      end }
      return layer
    end
    view.open = function() view.buf = nbuf() return view.buf end
    return view
  end
  return builder
end
function widgets_module.new_cursor_anchored_float_win(buf) return buf end
function widgets_module.with_resize(fn) return fn end
widgets_module.threads = {
  new_buf = function() return vim.api.nvim_create_buf(false, true) end,
  render = function(view)
    if not fake_session then
      view.layer().render({ 'No active session' })
      return
    end
    if not fake_session.stopped_thread_id then
      view.layer().render({ 'Not stopped at any breakpoint. No frames available' })
      return
    end
    local thread = fake_session.threads[fake_session.stopped_thread_id]
    if not thread then
      local msg = string.format("Stopped thread (%d) not found. Can't display frames",
        fake_session.stopped_thread_id)
      view.layer().render({ msg })
      return
    end
    -- Debugger payload: this shape must never be projected.
    view.layer().render({ 'fixture-thread-payload' })
  end,
}
widgets_module.frames = widgets_module.threads
widgets_module.expression = {
  new_buf = function() return vim.api.nvim_create_buf(false, true) end,
  render = function(view, expression)
    view.layer().render({ 'No active session' })
    -- The evaluate failure shape keeps the user expression verbatim.
    view.layer().render({ "Error evaluating '" .. tostring(expression) .. "':", '', 'fixture-err' })
  end,
}
widgets_module.scopes = { new_buf = widgets_module.expression.new_buf, render = function() end }
widgets_module.sessions = { new_buf = widgets_module.expression.new_buf, render = function() end }
package.loaded['dap.ui.widgets'] = widgets_module

local function new_session_module()
  return {
    _show_exception_info = function() end,
    spawn = function()
      -- Upstream: a bare vim.notify with the shared spawn-error template.
      vim.notify('Error running `fixture-cmd` of `fixture`: fixture-err', vim.log.levels.ERROR)
      vim.notify('fixture unrelated notification', vim.log.levels.WARN)
    end,
    connect = function(adapter, config, opts, on_connect)
      on_connect('Could not resolve fixture-host')
      on_connect('fixture-libuv-error')
    end,
  }
end
local versioned_session = new_session_module()
package.loaded['dap.session'] = versioned_session
local versioned_utils = { to_dict = function()
  vim.notify_once('dap.utils.to_dict is deprecated for removal in nvim-dap 0.10.0')
  vim.notify_once('fixture unrelated once')
end }
package.loaded['dap.utils'] = versioned_utils
package.loaded['dap.ext.vscode'] = {
  load_launchjs = function()
    vim.notify_once('dap.ext.vscode.load_launchjs is deprecated as it is no longer needed.'
      .. ' ./.vscode/launch.json files are read automatically on-demand. See :help dap-providers')
  end,
  getconfigs = function() return {} end,
}

enabled = true
adapter.attach(ctx)
local verified = adapter.info(ctx)
equal(verified.slots.widgets_builder.active, true, 'widgets builder seam missing')
equal(verified.slots.exception_info.active, true, 'exception diagnostic seam missing')
equal(verified.slots.spawn.active, true, 'spawn seam missing')
equal(verified.slots.connect.active, true, 'connect seam missing')
equal(verified.slots.to_dict.active, true, 'to_dict seam missing')
equal(verified.slots.load_launchjs.active, true, 'load_launchjs seam missing')

-- The widget and diagnostic projections are gated on the real pinned call site
-- (debug.getinfo against the loaded lua/dap/ui/widgets.lua and
-- lua/dap/session.lua). This offline fixture replaces those modules and has no
-- upstream tree, so the correct behaviour here is the documented fallback: the
-- seams own their entry points, the proxy is installed, and nothing is projected
-- because no pinned call site can be proven. Positive projection is asserted by
-- the upstream and TUI suites, which run the real plugin source.
captured_widget_lines = {}
fake_session = nil
local own_view = widgets_module.builder(widgets_module.threads).build()
own_view.open()
widgets_module.threads.render(own_view)
equal(captured_widget_lines[1], 'No active session', 'unpinned widget call site was projected')
local user_widget = {
  new_buf = function() return vim.api.nvim_create_buf(false, true) end,
  render = function(view) view.layer().render({ 'No active session' }) end,
}
local user_view = widgets_module.builder(user_widget).build()
user_view.open()
captured_widget_lines = {}
user_widget.render(user_view)
equal(captured_widget_lines[1], 'No active session', 'user widget translated')

-- spawn: the fixed template is projected, an unrelated message is untouched.
local notify_calls = {}
local real_notify = vim.notify
vim.notify = function(msg, level) notify_calls[#notify_calls + 1] = msg end
versioned_session.spawn()
vim.notify = real_notify
equal(notify_calls[1], '运行 `fixture-cmd`（所属 `fixture`）时出错： fixture-err', 'spawn projection')
equal(notify_calls[2], 'fixture unrelated notification', 'spawn leaked onto unrelated notification')

-- connect: only the resolve message is projected; other err values pass through.
local connected = {}
versioned_session.connect({}, {}, {}, function(err) connected[#connected + 1] = err end)
equal(connected[1], '无法解析 fixture-host', 'resolve projection')
equal(connected[2], 'fixture-libuv-error', 'libuv error was projected')

-- deprecated entries: only the exact msgid is projected.
local once_calls = {}
local real_once = vim.notify_once
vim.notify_once = function(msg) once_calls[#once_calls + 1] = msg end
versioned_utils.to_dict()
package.loaded['dap.ext.vscode'].load_launchjs()
vim.notify_once = real_once
equal(once_calls[1], 'dap.utils.to_dict 已弃用，将在 nvim-dap 0.10.0 中移除', 'to_dict projection')
equal(once_calls[2], 'fixture unrelated once', 'to_dict leaked onto unrelated once')
check(once_calls[3]:find('已弃用，不再需要', 1, true) ~= nil, 'load_launchjs projection')
check(once_calls[3]:find(':help dap-providers', 1, true) ~= nil, 'load_launchjs reference changed')

-- Unverified revision falls back to English for every versioned seam.
verified_surfaces = false
adapter.attach(ctx)
captured_widget_lines = {}
fake_session = nil
widgets_module.threads.render(own_view)
equal(captured_widget_lines[1], 'No active session', 'unverified widget revision translated')
local fallback_notify = {}
vim.notify = function(msg) fallback_notify[#fallback_notify + 1] = msg end
versioned_session.spawn()
vim.notify = real_notify
equal(fallback_notify[1], 'Error running `fixture-cmd` of `fixture`: fixture-err',
  'unverified notification revision translated')
verified_surfaces = true
adapter.attach(ctx)

print('NVIM_DAP_SPEC=PASS no_force_load prompt,action,process repl_scope quickfix,commas health external_override,generation,teardown versioned_ownership,widget,spawn,connect,deprecation,fallback')
