from adapter_tui import run


def repl(ui, enabled):
    ui.command('lua require("dap").repl.open()')
    ui.expect('dap>')
    ui.send(b'\x17wA.help\r')
    ui.expect('自定义命令：' if enabled else 'Custom commands:')
    ui.send(b'\x1bgg')
    ui.expect('命令：' if enabled else 'Commands:')
    ui.send(b'\x1b')
    ui.command('lua require("dap").repl.close()')
    ui.command('lua require("dap").repl.open()')
    ui.expect('dap>')


def notification(ui, enabled):
    ui.command('lua require("dap").focus_frame()')
    ui.expect('没有活动会话' if enabled else 'No active session')


def selection(ui, enabled):
    ui.command('lua require("dap.ui").pick_one({"first-choice","second-choice"}, "Select file: ", nil, function(x) vim.print(x) end)')
    ui.expect('选择文件：' if enabled else 'Select file:', 'first-choice')
    ui.send(b'2\r')
    ui.expect('second-choice')


def health(ui, enabled):
    ui.command('checkhealth dap')
    ui.expect('dap：适配器' if enabled else 'dap: Adapters')


def quickfix(ui, enabled):
    ui.command('edit debug-fixture.txt')
    ui.command('lua require("dap").set_breakpoint("counter > 0"); require("dap").list_breakpoints(true)')
    ui.expect('条件：counter > 0' if enabled else 'Condition: counter > 0', 'debug-fixture.txt')
    ui.send(b'\r')
    ui.command('cclose')
    ui.expect('DEBUG_FIXTURE_LINE')


def input_value(ui, enabled):
    ui.command('lua FixtureSetVariable()')
    ui.expect('`counter` 的新值：' if enabled else 'New `counter` value:')
    ui.send('41\r')
    ui.expect('DAP_VALUE_RECEIVED=41')


def launch_error(ui, enabled):
    # Real plugin branch: dap.lua:316-323 reports a launch.json read failure.
    # Upstream concatenates the caught error onto a literal "%s"; the adapter
    # projects the fixed prefix only and re-attaches the payload untouched.
    ui.command('lua FixtureLaunchError()')
    expected = '无法从 launch.json 获取配置' if enabled else "Can't get configurations from launch.json"
    frame = ui.expect(expected)
    if enabled:
        assert "Can't get configurations" not in frame, frame
        assert '%s' not in frame, frame
        assert 'fixture-launch-' in frame, frame
    ui.send(b'\r')
    ui.pump(0.2)


def help_topic(ui, enabled):
    ui.command('lua AdapterTestHelpTags()')
    ui.command('help dap-configuration')
    ui.expect('除了（可能）启动并连接调试适配器之外' if enabled else 'In addition to launching (possibly)')
    # Tags and the three required field names stay intact.
    ui.expect('dap-configuration', 'Configuration', 'request: string')


def threads(ui, enabled):
    ui.command('lua FixtureThreadLabel()')
    ui.expect('线程 | fixture-worker' if enabled else 'Threads | fixture-worker')


def widget(ui, enabled):
    # Real plugin render functions through the public dap.ui.widgets builder into
    # a real float. Debugger payload and the user expression stay byte-identical.
    def case(kind, expected_en, expected_en_disabled, reject_en):
        ui.command(f'lua FixtureWidget("{kind}")')
        ui.expect(expected_en if enabled else expected_en_disabled,
                  reject=(reject_en,) if enabled else ())
        ui.command('lua FixtureWidgetClose()')

    case('threads', '没有活动会话', 'No active session', 'No active session')
    case('frames-nosession', '没有活动会话', 'No active session', 'No active session')
    case('expression', '没有活动会话', 'No active session', 'No active session')
    case('frames-notstopped', '未停在任何断点处，没有可用的栈帧',
         'Not stopped at any breakpoint. No frames available', 'Not stopped at any breakpoint')
    case('frames-missing', '未找到已停止的线程（7）。无法显示栈帧',
         "Stopped thread (7) not found. Can't display frames", "not found. Can't display frames")
    case('frames-noframes', '已停止的线程没有栈帧', 'Stopped thread has no frames',
         'Stopped thread has no frames')
    # Expression is user data: the template must capture and re-emit it exactly.
    ui.command('lua FixtureWidget("expression-error")')
    ui.expect("求值 'obj.field[0] + 用户值' 时出错：" if enabled
              else "Error evaluating 'obj.field[0] + 用户值':",
              'DAP_EVAL_SENT=obj.field[0] + 用户值',
              reject=("Error evaluating 'obj.field[0] + 用户值'",) if enabled else ())
    ui.command('lua FixtureWidgetClose()')


def diagnostic(ui, enabled):
    # Real Session:_show_exception_info through its request path. The diagnostic
    # is observed at vim.diagnostic.set so the message the plugin passed is
    # asserted directly; the type, break mode, description, stack trace and
    # vim.inspect'd inner exceptions stay byte-identical.
    ui.command('lua FixtureExceptionInfo()')
    expected = ('线程因类型 RuntimeError 的异常而停止（exception）' if enabled
                else 'Thread stopped due to exception of type RuntimeError (exception)')
    ui.expect('DAP_DIAG=' + expected,
              reject=('DAP_DIAG=Thread stopped due to exception of type',) if enabled else ())
    # Without details.typeName (:357 builds an empty ' of type ' suffix) the
    # shorter template must match and no ' of type ' remnant may survive.
    ui.expect('DAP_DIAG_PLAIN=' + ('线程因异常而停止（always）' if enabled
                                   else 'Thread stopped due to exception (always)'),
              reject=('DAP_DIAG_PLAIN=Thread stopped due to exception of type',) if enabled else ())
    ui.expect('DAP_DIAG_DESC=' + ('描述：fixture description text' if enabled
                                  else 'Description: fixture description text'),
              reject=('DAP_DIAG_DESC=Description:',) if enabled else ())
    ui.expect('DAP_DIAG_TRACE=' + ('栈跟踪：' if enabled else 'Stack trace:'),
              reject=('DAP_DIAG_TRACE=Stack trace:',) if enabled else ())
    # The stack trace body and the inner exception payload stay verbatim.
    ui.expect('DAP_DIAG_BODY=at main (fixture.py:3)',
              'DAP_DIAG_INNER=typeName = "InnerFixture"')


def deprecation(ui, enabled):
    # Both deprecated public entries use a bare vim.notify_once with one fixed
    # string and no title; only that exact msgid is projected.
    ui.command('lua FixtureDeprecated()')
    ui.expect('DAP_ONCE_TO_DICT=' + ('dap.utils.to_dict 已弃用，将在 nvim-dap 0.10.0 中移除' if enabled
              else 'dap.utils.to_dict is deprecated for removal in nvim-dap 0.10.0'),
              reject=('DAP_ONCE_TO_DICT=dap.utils.to_dict is deprecated',) if enabled else ())
    # The load_launchjs message is long and wraps; assert a distinctive slice and
    # the untouched ':help dap-providers' reference.
    ui.expect(('DAP_ONCE_LAUNCHJS=dap.ext.vscode.load_launchjs 已弃用' if enabled
               else 'DAP_ONCE_LAUNCHJS=dap.ext.vscode.load_launchjs is deprecated'),
              ':help dap-providers',
              reject=('is deprecated as it is no longer needed',) if enabled else ())
    # Dedup semantics and every other notification stay untouched.
    ui.expect('DAP_ONCE_UNRELATED=unrelated once message')


def spawn_error(ui, enabled):
    # Real Session.spawn failure branch (session.lua:1621-1630): bare vim.notify
    # with no title. The spawn templates are shared with the utils.notify path.
    ui.command('lua FixtureSpawnError()')
    expected = '找不到可执行文件 `/nonexistent-fixture-binary`，请修正 `fixture` 的适配器定义（' if enabled         else 'Executable `/nonexistent-fixture-binary` not found, fix the adapter definition for `fixture` ('
    ui.expect('DAP_SPAWN=' + expected,
              reject=('DAP_SPAWN=Executable `/nonexistent-fixture-binary` not found',) if enabled else ())
    # A non-matching notification raised while the scoped proxy is active reaches
    # the original vim.notify unchanged.
    ui.expect('DAP_SPAWN_UNRELATED=fixture unrelated notification')


def resolve_error(ui, enabled):
    # Real Session.connect: no addresses and no libuv error produces
    # 'Could not resolve <host>' (:1486) which reaches the caller's on_connect.
    ui.command('lua FixtureResolveError()')
    ui.expect('DAP_CONNECT=' + ('无法解析 fixture-host' if enabled else 'Could not resolve fixture-host'),
              reject=('DAP_CONNECT=Could not resolve',) if enabled else ())
    # A libuv connect error is not the fixed template and passes through.
    ui.command('lua FixtureConnectLibuvError()')
    ui.expect('DAP_CONNECT_LIBUV=fixture-libuv-connect-error')


def repl_no_session(ui, enabled):
    # repl.lua:299 force-appends 'No active debug session' when a command runs
    # with no session and no autostart. The dap> prompt stays verbatim.
    ui.command('lua require("dap").repl.open()')
    ui.expect('dap>')
    ui.send(b'\x17wAcontinue\r')
    ui.expect('dap> continue',
              '没有活动的调试会话' if enabled else 'No active debug session',
              reject=('No active debug session',) if enabled else ())
    # The command token is behaviour, not display copy, and is never rewritten.
    ui.expect('dap> continue')
    ui.send(b'\x1b')
    ui.command('lua require("dap").repl.close()')


run('nvim-dap', {'repl': repl, 'notification': notification, 'selection': selection, 'health': health,
                 'quickfix': quickfix, 'input': input_value, 'threads': threads,
                 'launch_error': launch_error, 'help': help_topic, 'widget': widget,
                 'diagnostic': diagnostic, 'deprecation': deprecation, 'spawn_error': spawn_error,
                 'resolve_error': resolve_error, 'repl_no_session': repl_no_session},
    dependencies=('NVIM_ZH_TEST_NVIM_DAP',),
    verify=True,
    files={'debug-fixture.txt': 'DEBUG_FIXTURE_LINE\n'},
    setup="""
vim.cmd('runtime plugin/dap.lua')
require('dap')
require('dap.ui')
require('dap.repl')
require('dap.health')
require('dap.breakpoints')
require('dap.entity')
-- Load every pinned surface module before the adapter attaches, so the versioned
-- seams own their entry points on the first fixture call instead of on a later
-- startup sweep.
require('dap.ui.widgets')
require('dap.session')
require('dap.utils')
require('dap.ext.vscode')
require('nvim-zh').refresh()
-- Fixture diagnostics. A single multi-line message keeps every reported line on
-- screen at once, so assertions read real terminal content; :echo would only
-- retain the last message and make multi-line assertions racy.
function FixtureReport(lines)
  vim.api.nvim_echo({{ table.concat(lines, '\\n') }}, false, {})
end
function AdapterTestHelpTags()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/doc', 'p')
  local source = vim.env.NVIM_ZH_TEST_NVIM_DAP .. '/doc/dap.txt'
  assert(vim.uv.fs_copyfile(source, root .. '/doc/dap.txt'))
  vim.cmd.helptags(root .. '/doc')
  vim.opt.rtp:append(root)
  require('nvim-zh').refresh()
end
function FixtureLaunchError()
  require('dap')
  require('dap.ext.vscode')
  local dap = require('dap')
  local original = package.loaded['dap.ext.vscode'].getconfigs
  package.loaded['dap.ext.vscode'].getconfigs = function() error('fixture-launch-error') end
  pcall(dap.providers.configs['dap.launch.json'])
  vim.wait(150)
  package.loaded['dap.ext.vscode'].getconfigs = original
end
function FixtureSetVariable()
  local dap = require('dap')
  local original = dap.session
  dap.session = function() return {
    capabilities = { supportsSetVariable = true }, current_frame = { id = 1 },
    request = function(_, command, args)
      assert(command == 'setVariable' and args.name == 'counter' and args.variablesReference == 9)
      vim.api.nvim_echo({{ 'DAP_VALUE_RECEIVED=' .. args.value }}, false, {})
    end,
  } end
  local item = { name = 'counter', parent = { variablesReference = 9 } }
  local action = require('dap.entity').variable.tree_spec.compute_actions({ item = item, context = {} })[1]
  local ok, failure = pcall(action.fn, nil, item, 0, {})
  dap.session = original
  if not ok then error(failure) end
end
function FixtureThreadLabel()
  local widget = require('dap.entity').threads.tree_spec
  local worker = { id = 2, name = 'fixture-worker' }
  local root = { id = 0, name = 'Threads', threads = { worker } }
  vim.api.nvim_echo({{ widget.render_parent(root) .. ' | ' .. widget.render_parent(worker) }}, false, {})
end
-- Renders a real dap.ui.widgets widget through the public builder into a real
-- floating window and leaves it open, so the assertions read the actual screen
-- the user would see. The widget tables and render functions are the plugin's own.
function FixtureWidget(kind)
  local real = require('dap')
  local function with_session(make)
    package.loaded['dap'] = setmetatable({ session = make, sessions = function() return {} end,
      listeners = real.listeners }, { __index = real })
  end
  local expr
  if kind == 'threads' or kind == 'frames-nosession' or kind == 'expression' then
    with_session(function() return nil end)
  elseif kind == 'frames-notstopped' then
    with_session(function() return { capabilities = {}, stopped_thread_id = nil, threads = {} } end)
  elseif kind == 'frames-missing' then
    with_session(function() return { capabilities = {}, stopped_thread_id = 7, threads = {} } end)
  elseif kind == 'frames-noframes' then
    with_session(function()
      return { capabilities = {}, stopped_thread_id = 7, threads = { [7] = { id = 7 } },
        request = function() return 'fixture-stack-error', nil end }
    end)
  elseif kind == 'expression-error' then
    expr = 'obj.field[0] + 用户值'
    with_session(function()
      return { capabilities = {}, current_frame = { scopes = {} },
        evaluate = function(_, args, cb)
          vim.g.dap_fixture_expression = args.expression
          cb('fixture-eval-error', nil)
        end }
    end)
  end
  local widgets = require('dap.ui.widgets')
  local target = kind:match('^frames') and widgets.frames
    or (kind == 'threads' and widgets.threads or widgets.expression)
  -- Build through the public builder, then attach a real buffer and a real
  -- floating window so the plugin's own render function draws on screen.
  local view = widgets.builder(target)
    .new_win(widgets.with_resize(widgets.new_cursor_anchored_float_win))
    .build()
  local buf = vim.api.nvim_create_buf(false, true)
  view.buf = buf
  view.win = vim.api.nvim_open_win(buf, false,
    { relative = 'editor', row = 0, col = 0, width = 78, height = 6, style = 'minimal' })
  vim.bo[buf].modifiable = true
  target.render(view, expr)
  vim.wait(150)
  package.loaded['dap'] = real
  if kind == 'expression-error' then
    FixtureReport({ 'DAP_EVAL_SENT=' .. tostring(vim.g.dap_fixture_expression) })
  end
  vim.g.dap_fixture_widget = view
end
function FixtureWidgetClose()
  local view = vim.g.dap_fixture_widget
  if view then pcall(view.close, view) end
  vim.g.dap_fixture_widget = nil
end
-- Real Session:_show_exception_info. vim.diagnostic.set is observed only to make
-- the emitted diagnostic visible in the test terminal; the message the plugin
-- passed is echoed line by line, unchanged.
function FixtureExceptionInfo()
  local real_set = vim.diagnostic.set
  local pending = {}
  vim.diagnostic.set = function(ns, bufnr, items, ...)
    local item = items[1]
    local lines = vim.split(item.message, '\\n', { plain = true })
    local report = {}
    for _, line in ipairs(lines) do
      if line:match('^描述：') or line:match('^Description: ') then
        report[#report + 1] = 'DAP_DIAG_DESC=' .. line
      elseif line:match('^栈跟踪：') or line == 'Stack trace:' then
        report[#report + 1] = 'DAP_DIAG_TRACE=' .. line
      elseif line:match('^at main ') then
        report[#report + 1] = 'DAP_DIAG_BODY=' .. line
      elseif line:match('typeName = "InnerFixture"') then
        report[#report + 1] = 'DAP_DIAG_INNER=typeName = "InnerFixture"'
      end
    end
    pending[#pending + 1] = { first = lines[1], report = report }
    return real_set(ns, bufnr, items, ...)
  end
  local session = require('dap.session')
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
  local function show(response)
    local self = {
      capabilities = { supportsExceptionInfoRequest = true },
      ns = vim.api.nvim_create_namespace('dap-fixture-' .. tostring(vim.uv.hrtime())),
      request = function() return nil, response end,
    }
    -- _show_exception_info yields through self:request; drive it in a coroutine
    -- exactly like dap.async.run does.
    local co = coroutine.create(function()
      session._show_exception_info(self, 1, buf, { line = 2, column = 1 })
    end)
    local ok, failure = coroutine.resume(co)
    if not ok then error(failure) end
  end
  show({ breakMode = 'exception', description = 'fixture description text',
    details = { typeName = 'RuntimeError', stackTrace = 'at main (fixture.py:3)',
      innerException = { { typeName = 'InnerFixture' } } } })
  show({ breakMode = 'always' })
  vim.diagnostic.set = real_set
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  local typed, plain = pending[1], pending[2]
  local report = { 'DAP_DIAG=' .. typed.first }
  -- The shorter template must match when details.typeName is absent (:357).
  report[#report + 1] = 'DAP_DIAG_PLAIN=' .. plain.first
  for _, line in ipairs(typed.report) do report[#report + 1] = line end
  FixtureReport(report)
end
function FixtureDeprecated()
  local real = vim.notify_once
  local seen = {}
  vim.notify_once = function(msg, ...)
    seen[#seen + 1] = msg
    return real(msg, ...)
  end
  local ok, failure = pcall(function()
    require('dap.utils').to_dict({ 1, 2 }, function(v) return v end)
  end)
  if not ok then error(failure) end
  require('dap.ext.vscode').getconfigs = function() return {} end
  pcall(require('dap.ext.vscode').load_launchjs)
  vim.notify_once('unrelated once message')
  vim.notify_once = real
  local report = {}
  for _, message in ipairs(seen) do
    if message:find('to_dict', 1, true) then
      report[#report + 1] = 'DAP_ONCE_TO_DICT=' .. message
    elseif message:find('load_launchjs', 1, true) then
      report[#report + 1] = 'DAP_ONCE_LAUNCHJS=' .. message
    else
      report[#report + 1] = 'DAP_ONCE_UNRELATED=' .. message
    end
  end
  FixtureReport(report)
end
-- Real Session.spawn failure branch: uv.spawn is forced to fail for the one
-- call so the fixed session.lua:1621-1630 notify+return path runs.
function FixtureSpawnError()
  -- The spy both records and forwards: reaching it at all proves the adapter
  -- passed the call through to the real vim.notify. Nothing is displayed through
  -- it so the two facts below can be reported in one message.
  local real_notify = vim.notify
  local report = {}
  vim.notify = function(msg, level, opts)
    -- The adapter's own scoped proxy sits above this spy, so a projected spawn
    -- failure arrives here already translated; match either wording.
    if type(msg) == 'string'
      and (msg:find('not found, fix the adapter definition', 1, true)
        or msg:find('找不到可执行文件', 1, true)) then
      report[#report + 1] = 'DAP_SPAWN=' .. msg
    elseif type(msg) == 'string' and msg:find('unrelated notification', 1, true) then
      report[#report + 1] = 'DAP_SPAWN_UNRELATED=' .. msg
    else
      report[#report + 1] = 'DAP_SPAWN_OTHER=' .. tostring(msg)
    end
    return true
  end
  local ok, failure = pcall(require('dap.session').spawn, {
    type = 'executable', command = '/nonexistent-fixture-binary', args = {},
    options = { cwd = vim.fn.getcwd(), detached = false },
  }, { type = 'fixture', name = 'fixture' }, {})
  -- A notification raised while the scoped proxy is active must reach the
  -- original vim.notify untouched.
  vim.notify('fixture unrelated notification', vim.log.levels.WARN)
  vim.notify = real_notify
  if not ok then error(failure) end
  FixtureReport(report)
end
function FixtureResolveError()
  local uv = vim.uv
  local real_addresses, real_tcp = uv.getaddrinfo, uv.new_tcp
  local report = {}
  uv.getaddrinfo = function(host, port, hints, cb) cb(nil, {}) end
  uv.new_tcp = function()
    return {
      connect = function() end, is_closing = function() return true end,
      close = function() end, shutdown = function() end,
    }
  end
  local ok, failure = pcall(function()
    return require('dap.session').connect({ type = 'server', host = 'fixture-host', port = 1 },
      { type = 'fixture', name = 'fixture' }, {},
      function(err) report[#report + 1] = 'DAP_CONNECT=' .. tostring(err) end)
  end)
  uv.getaddrinfo, uv.new_tcp = real_addresses, real_tcp
  if not ok then error(failure) end
  FixtureReport(report)
end
function FixtureConnectLibuvError()
  local uv = vim.uv
  local real_addresses, real_tcp = uv.getaddrinfo, uv.new_tcp
  local report = {}
  uv.getaddrinfo = function(host, port, hints, cb) cb(nil, { { addr = '127.0.0.1' } }) end
  uv.new_tcp = function()
    return {
      connect = function(_, _, _, cb) cb('fixture-libuv-connect-error') end,
      is_closing = function() return true end,
      close = function() end, shutdown = function() end,
    }
  end
  local ok, failure = pcall(function()
    return require('dap.session').connect(
      { type = 'server', host = '127.0.0.1', port = 1, options = { max_retries = 1 } },
      { type = 'fixture', name = 'fixture' }, {},
      function(err) report[#report + 1] = 'DAP_CONNECT_LIBUV=' .. tostring(err) end)
  end)
  uv.getaddrinfo, uv.new_tcp = real_addresses, real_tcp
  if not ok then error(failure) end
  FixtureReport(report)
end
""")
