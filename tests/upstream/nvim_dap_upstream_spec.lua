local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local upstream = assert(vim.env.NVIM_ZH_TEST_NVIM_DAP, 'fixed nvim-dap sources are required')
vim.opt.runtimepath:prepend(upstream)
local commit = vim.fn.readfile(upstream .. '/.git/HEAD')[1]
check(commit, 'fixed upstream HEAD is unreadable')

local entries = {
  notification = {
    ['No configuration found for `%s`. You need to add configs to `dap.configurations.%s` (See `:h dap-configuration`)'] =
      '未找到 `%s` 的配置。请在 `dap.configurations.%s` 中添加配置（参见 `:h dap-configuration`）',
    ['No active session'] = '没有活动会话',
  },
  prompt = {
    ['Configuration: '] = '配置： ',
    ['Exception breakpoint filters: '] = '异常断点筛选器： ',
    ['New `%s` value: '] = '`%s` 的新值： ',
    ['Actions> '] = '操作> ',
    ['Select process: '] = '选择进程： ',
  },
  action = {
    Expand = '展开',
    ['Terminate session'] = '终止会话',
  },
  process = { ['id=%d name=%s'] = 'id=%d，名称=%s' },
  repl_help = {
    ['Commands:'] = '命令：',
    ['Custom commands:'] = '自定义命令：',
  },
  repl_hint = {
    ['(press enter on line to jump to frame)'] = '（在行上按 Enter 跳转到帧）',
  },
  mapping = {
    ['Move to next prompt'] = '移动到下一个提示符',
    ['Move to previous prompt'] = '移动到上一个提示符',
  },
  quickfix = {
    Rejected = '已拒绝',
    ['Rejected: %s'] = '已拒绝：%s',
    ['Log message: %s'] = '日志消息：%s',
    ['Condition: %s'] = '条件：%s',
    ['Hit condition: %s'] = '命中条件：%s',
  },
  health = {
    ['Missing required `command` property'] = '缺少必需的 `command` 属性',
    ['Adapter is a function. Can\'t validate it'] = '适配器是函数，无法验证',
    ['%s must be one of: executable, server or pipe'] = '%s 必须是以下值之一：executable、server 或 pipe',
    ['dap: Adapters'] = 'dap：适配器',
    ['dap: Sessions'] = 'dap：会话',
    ['No active sessions'] = '没有活动会话',
  },
  widget = { Threads = '线程' },
}

-- The upstream spec consumes the real PO text, not a shared generated catalog.
local po = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/nvim-dap.po'), '\n')
for context, values in pairs(entries) do
  for msgid, msgstr in pairs(values) do
    local block = ('msgctxt "%s"\nmsgid "%s"\nmsgstr "%s"'):format(context, msgid, msgstr)
    check(po:find(block, 1, true) ~= nil, 'PO/source fixture mismatch: ' .. context .. ':' .. msgid)
  end
end

local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end
require('nvim-zh.engine').setup({
  overrides = { ['nvim-dap'] = entries },
  missing = { enabled = true, max_entries = 128 },
})
require('nvim-zh.ui').setup({ notify = true, prompts = false, select_items = false, echo = false })

local adapter = require('nvim-zh.adapters.nvim_dap')
local common = require('nvim-zh.adapters.common')
local ctx = {
  enabled = function() return true end,
  translate = common.translate,
  register_source = function(spec) return require('nvim-zh.ui').register_source(spec) end,
}
adapter.attach(ctx)
check(package.loaded['dap'] == nil and package.loaded['dap.repl'] == nil,
  'adapter attach forced nvim-dap modules to load')

local dap = require('dap')
dap.adapters = {}
dap.configurations = {}
vim.bo.filetype = ''
notifications = {}
dap.continue()
check(vim.wait(3000, function() return #notifications >= 1 end, 10), 'no-config notification not delivered')
equal(notifications[1].msg,
  '未找到 `` 的配置。请在 `dap.configurations.` 中添加配置（参见 `:h dap-configuration`）',
  'real no-config notification')
equal(notifications[1].level, vim.log.levels.INFO, 'notification level changed')
equal(notifications[1].opts.title, 'DAP', 'notification title changed')
require('dap.utils').notify('Commands:', vim.log.levels.INFO)
equal(notifications[#notifications].msg, 'Commands:', 'debugger/unknown text was translated by notification route')

-- Capture every original before the first attach that can see these modules.
-- dap.repl requires dap.ui internally, and dap itself loads several other leaf
-- modules; capturing later would mistake our own wrappers for upstream originals.
local ui = require('dap.ui')
local breakpoints = require('dap.breakpoints')
local health = require('dap.health')
local entity = require('dap.entity')
local Session = require('dap.session')
local original_pick, original_sync = ui.pick_one, ui.pick_one_sync
local original_qf = breakpoints.to_qf_list
local original_health_check = health.check
local original_root = entity.threads.tree_spec.render_parent
local original_variable_actions = entity.variable.tree_spec.compute_actions
local original_exception = Session.set_exception_breakpoints

-- Require first, then re-sync: the first real REPL buffer is still covered.
local repl = require('dap.repl')
local original_repl = {
  execute = repl.execute,
  append = repl.append,
  open = repl.open,
  toggle = repl.toggle,
  print_stackframes = repl.print_stackframes,
}
adapter.attach(ctx)
local wrapped_append = repl.append
adapter.attach(ctx)
equal(repl.append, wrapped_append, 'repeated attach stacked REPL append wrappers')
local repl_buf, repl_win = repl.open()
check(repl_buf and repl_win, 'real REPL did not open')
local initial = vim.api.nvim_buf_get_lines(repl_buf, 0, -1, false)
equal(#initial, 1, 'REPL gained an invented welcome message')
equal(initial[1], 'dap> ', 'REPL prompt was translated or changed')

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(repl_buf, 0, -1, false), '\n')
end
local function count_exact_line(needle)
  local count = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(repl_buf, 0, -1, false)) do
    if line == needle then count = count + 1 end
  end
  return count
end

repl.execute('.help')
local helped = buffer_text()
check(helped:find('命令：', 1, true) ~= nil, 'real .help Commands label not translated')
check(helped:find('自定义命令：', 1, true) ~= nil, 'real .help Custom commands label not translated')
check(helped:find('.continue, .c', 1, true) ~= nil, 'REPL command tokens were translated')
check(helped:find('Commands:', 1, true) == nil, 'English Commands label remained after real .help')
repl.append('Commands:')
local after_output = buffer_text()
equal(count_exact_line('命令：'), 1, 'help label translated more than once')
equal(count_exact_line('Commands:'), 1, 'same-named debugger output was translated outside .help')
check(after_output:find('dap> ', 1, true) ~= nil, 'REPL prompt changed after help/output')

local maps = vim.api.nvim_buf_get_keymap(repl_buf, 'n')
local descs = {}
for _, map in ipairs(maps) do descs[map.lhs] = map.desc end
equal(descs[']]'], '移动到下一个提示符', 'next-prompt mapping description')
equal(descs['[['], '移动到上一个提示符', 'previous-prompt mapping description')

-- Real dap.ui select projection: prompt and structural action labels only.
adapter.attach(ctx)
local old_vim_select = vim.ui.select
local select_capture
vim.ui.select = function(items, opts, callback)
  select_capture = { items = items, opts = opts, callback = callback }
  return callback(items[1])
end
local config = { name = 'User configuration' }
local selected
ui.pick_one({ config }, 'Configuration: ', function(item) return item.name end, function(item) selected = item end)
check(vim.wait(1000, function() return selected ~= nil end, 10), 'real scheduled select callback did not run')
equal(select_capture.opts.prompt, '配置： ', 'real select prompt')
equal(select_capture.opts.format_item(config), 'User configuration', 'user configuration name changed')
check(selected == config, 'real select changed item identity')
local action = { label = 'Expand', fn = function() end }
ui.pick_one({ action }, 'Actions> ', function(item) return item.label end, function() end)
equal(select_capture.opts.format_item(action), '展开', 'real action label')
local dap_target = { id = 3, label = 'Expand' }
equal(select_capture.opts.format_item(dap_target), 'Expand', 'DAP target label changed')
local process = { pid = 42, name = 'python,worker' }
ui.pick_one({ process }, 'Select process: ', function(item)
  return ('id=%d name=%s'):format(item.pid, item.name)
end, function() end)
equal(select_capture.opts.format_item(process), 'id=42，名称=python,worker', 'real process label')
vim.ui.select = old_vim_select

-- Real quickfix formatter: user text can contain commas and even English labels.
adapter.attach(ctx)
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
equal(qf[1].text,
  'local x = "a,b", 已拒绝：adapter, raw, 日志消息：x, Condition: user-data, 条件：a,b, 命中条件：2',
  'real quickfix projection')
check(vim.deep_equal(input, original_input), 'real quickfix projection mutated input')

-- Real health module with a scoped vim.health proxy.
adapter.attach(ctx)
local old_health = vim.health
local health_messages = {}
vim.health = {
  start = function(msg) health_messages[#health_messages + 1] = msg end,
  ok = function(msg) health_messages[#health_messages + 1] = msg end,
  info = function(msg) health_messages[#health_messages + 1] = msg end,
  warn = function(msg) health_messages[#health_messages + 1] = msg end,
  error = function(msg) health_messages[#health_messages + 1] = msg end,
}
dap.adapters = {
  missing = { type = 'executable' },
  callback = function() end,
  bad = { type = 'invalid' },
}
local health_sink = vim.health
health.check()
equal(vim.health, health_sink, 'health proxy was not restored')
local health_text = table.concat(health_messages, '\n')
check(health_text:find('缺少必需的 `command` 属性', 1, true) ~= nil, 'real health missing command')
check(health_text:find('适配器是函数，无法验证', 1, true) ~= nil, 'real health function adapter')
check(health_text:find('invalid 必须是以下值之一：executable、server 或 pipe', 1, true) ~= nil,
  'real health dynamic adapter type')
check(health_text:find('没有活动会话', 1, true) ~= nil, 'real health sessions')
health.check()
equal(vim.health, health_sink, 'health proxy was not restored on repeat')
vim.health = old_health
dap.adapters = {}

-- Only the structurally synthetic root is translated, never a same-named DAP thread.
adapter.attach(ctx)
local root = { id = 0, name = 'Threads', threads = { { id = 2, name = 'worker' } } }
equal(entity.threads.tree_spec.render_parent(root), '线程', 'real synthetic Threads root')
equal(entity.threads.tree_spec.render_parent({ id = 2, name = 'Threads' }), 'Threads',
  'real DAP thread name changed')

-- The three vim.fn.input prompts have their own synchronous source seams.
adapter.attach(ctx)
local old_input = vim.fn.input
local input_calls = {}
vim.fn.input = function(prompt, default)
  input_calls[#input_calls + 1] = { prompt = prompt, default = default }
  return 'uncaught'
end
local input_spy = vim.fn.input
local exception_request
local exception_session = {
  capabilities = { exceptionBreakpointFilters = { { filter = 'uncaught', label = 'Uncaught' } } },
  request = function(_, command, args, callback)
    exception_request = { command = command, args = args }
    if callback then callback(nil, {}) end
  end,
}
Session.set_exception_breakpoints(exception_session, nil, nil)
equal(input_calls[#input_calls].prompt, '异常断点筛选器： ', 'real exception filter prompt')
equal(input_calls[#input_calls].default, 'uncaught', 'exception filter default values changed')
equal(exception_request.command, 'setExceptionBreakpoints', 'exception request command changed')
check(vim.deep_equal(exception_request.args.filters, { 'uncaught' }), 'exception filters were translated')
check(vim.fn.input == input_spy, 'Session input wrapper leaked')

local fake_session = {
  capabilities = { supportsSetVariable = true },
  current_frame = { id = 1 },
  requests = {},
}
function fake_session:request(command, args, callback)
  self.requests[#self.requests + 1] = { command = command, args = args, callback = callback }
end
local original_dap_session = dap.session
dap.session = function() return fake_session end
local action_item = { name = 'x', parent = { variablesReference = 9 } }
local projected_actions = entity.variable.tree_spec.compute_actions({ item = action_item, context = {} })
equal(#projected_actions, 1, 'real Set variable action inventory changed')
equal(projected_actions[1].label, 'Set variable', 'real action label was mutated')
local retained_set_variable = projected_actions[1].fn
local action_done = false
vim.schedule(function()
  projected_actions[1].fn(nil, action_item, 0, {})
  action_done = true
end)
check(vim.wait(3000, function() return action_done end, 10), 'scheduled Set variable action did not run')
equal(input_calls[#input_calls].prompt, '`x` 的新值： ', 'real Set variable prompt after async selection')
local set_request = fake_session.requests[#fake_session.requests]
equal(set_request.command, 'setVariable', 'Set variable request command changed')
equal(set_request.args.name, 'x', 'Set variable name changed')
equal(set_request.args.value, 'uncaught', 'Set variable input value changed')
equal(set_request.args.variablesReference, 9, 'Set variable parent reference changed')
check(vim.fn.input == input_spy, 'variable action input wrapper leaked')
vim.fn.input = old_input

-- Real module generation: restore the old owner, attach the new one, and never
-- reclaim a same-generation external replacement.
package.loaded['dap.ui'] = nil
local new_ui = require('dap.ui')
local new_original_pick, new_original_sync = new_ui.pick_one, new_ui.pick_one_sync
adapter.attach(ctx)
equal(ui.pick_one, original_pick, 'old real UI pick_one was not restored')
equal(ui.pick_one_sync, original_sync, 'old real UI pick_one_sync was not restored')
check(new_ui.pick_one ~= new_original_pick and new_ui.pick_one_sync ~= new_original_sync,
  'new real UI generation not attached')
local owned_new_pick = new_ui.pick_one
local external = function() return 'external' end
new_ui.pick_one = external
adapter.attach(ctx)
equal(new_ui.pick_one, external, 'real external override was reclaimed')
equal(adapter.info(ctx).slots.pick_one.reason, 'external_override', 'real external override not reported')
new_ui.pick_one = owned_new_pick
adapter.attach(ctx)

adapter.detach()
equal(new_ui.pick_one, new_original_pick, 'new real UI teardown failed')
equal(new_ui.pick_one_sync, new_original_sync, 'new real UI sync teardown failed')
equal(repl.execute, original_repl.execute, 'REPL execute teardown failed')
equal(repl.append, original_repl.append, 'REPL append teardown failed')
equal(repl.open, original_repl.open, 'REPL open teardown failed')
equal(repl.toggle, original_repl.toggle, 'REPL toggle teardown failed')
equal(repl.print_stackframes, original_repl.print_stackframes, 'REPL frames teardown failed')
equal(breakpoints.to_qf_list, original_qf, 'quickfix teardown failed')
equal(health.check, original_health_check, 'health teardown failed')
equal(entity.threads.tree_spec.render_parent, original_root, 'thread root teardown failed')
equal(entity.variable.tree_spec.compute_actions, original_variable_actions, 'variable actions teardown failed')
equal(Session.set_exception_breakpoints, original_exception, 'exception input teardown failed')
check(adapter.info(ctx).notification.active == false, 'notification source remained registered')

notifications = {}
require('dap.utils').notify('No active session', vim.log.levels.INFO)
equal(notifications[#notifications].msg, 'No active session', 'notification translation survived adapter detach')
repl.close()
require('nvim-zh.ui').teardown()
print('NVIM_DAP_UPSTREAM_SPEC=PASS commit=cfa2d58 no_config,first_repl,help_scope select,direct_input,quickfix,health generation,external_override,teardown')
