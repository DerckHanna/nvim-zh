import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

from adapter_tui import Terminal, init_for, lua_literal
from help_parity import example_blocks, links, tags

HERE = Path(__file__).resolve().parent
ID = 'nvim-dap-view'
DEPS = ('NVIM_ZH_TEST_NVIM_DAP', 'NVIM_ZH_TEST_NVIM_DAP_VIEW')
SETUP = """
vim.o.mouse = 'a'
vim.o.winborder = 'single'
vim.opt.shortmess:append('F')
vim.cmd('runtime plugin/dap-view.lua')
function DvSetup(options)
  require('dap-view').setup(vim.tbl_deep_extend('force', {
    winbar = { sections = {'scopes', 'threads', 'breakpoints', 'watches',
      'exceptions', 'sessions', 'console', 'repl'}, default_section = 'scopes',
      base_sections = { scopes = { keymap = 'L' } } },
    windows = { size = 0.4 },
  }, options or {}))
end
local fixture = vim.env.NVIM_ZH_DAP_VIEW_FIXTURE
if fixture then dofile(fixture) end
"""
F5, F8, F10 = b'\x1b[15~', b'\x1b[19~', b'\x1b[21~'
NO_ACTIVE = ('无活动调试会话', 'No active session')


def tr(enabled, chinese, english):
    return chinese if enabled else english


def capture(ui, name, *needles, reject=(), timeout=7):
    frame = ui.expect(*needles, reject=reject, timeout=timeout)
    destination = os.environ.get('NVIM_ZH_DAP_VIEW_EVIDENCE')
    if destination:
        directory = Path(destination)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f'{ui.evidence_name}-{name}.txt'
        path.write_text(f'{ui.screen.rows}x{ui.screen.cols} cursor={ui.screen.cursor()}\n{frame}\n', encoding='utf-8')
    return frame


def lua(ui, expression):
    ui.command('lua ' + expression)


def probe(ui, expression):
    ui.assertion = getattr(ui, 'assertion', 0) + 1
    marker = ui.temp / f'assertion-{ui.assertion:03}'
    lua(ui, f'assert({expression}); vim.fn.writefile({{"ok"}}, {lua_literal(str(marker))})')
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline and not ui.exited:
        ui.pump(.05)
        if marker.exists():
            return
    raise AssertionError(f'Behavior assertion failed: {expression}\n{ui.screen.text()}')


def dismiss_error(ui):
    if 'Press ENTER' in ui.screen.text():
        ui.send(b'\r')
        ui.expect(reject=('Press ENTER',))


def fixture(ui, mode):
    lua(ui, 'DvFixture(' + lua_literal(mode) + ')')


def open_view(ui, section):
    ui.command('DapViewJump ' + section)


def mapping(ui, enabled, section, keys):
    for key, chinese, english in keys:
        ui.command('nmap <buffer> ' + key)
        name = f'mapping-{section}-{key}'.replace('?', 'help').replace('<', '').replace('>', '')
        capture(ui, name, tr(enabled, chinese, english))
        dismiss_error(ui)


def click(ui, label):
    cells = ui.screen.cells()
    rows, cols = ui.screen.rows, ui.screen.cols
    for row in range(rows):
        for col in range(cols):
            pos = col
            for char in label:
                offset = (row * cols + pos) * 8
                if pos >= cols or cells[offset] != ord(char):
                    break
                pos += cells[offset + 6]
            else:
                ui.send(f'\x1b[<0;{col+1};{row+1}M\x1b[<0;{col+1};{row+1}m')
                return
    raise AssertionError(f'Could not click {label!r}\n{ui.screen.text()}')


def panel(ui, enabled):
    ui.command('DapViewOpen')
    titles = tr(enabled, ('变量 [L]', '线程 [T]', '断点 [B]', '监视 [W]', '异常 [E]', '会话 [K]',
                          '终端 [C]', '调试交互（REPL） [R]'),
                ('Scopes [L]', 'Threads [T]', 'Breakpoints [B]', 'Watches [W]', 'Exceptions [E]',
                 'Sessions [K]', 'Console [C]', 'REPL [R]'))
    no_session = tr(enabled, *NO_ACTIVE)
    capture(ui, 'first-open', *titles, no_session)
    assert ui.screen.widths(titles[0].split()[0]) == ([2, 2] if enabled else [1] * 6)
    click(ui, titles[2])
    capture(ui, 'breakpoint-click', tr(enabled, '暂无断点', 'No breakpoints'))
    open_view(ui, 'breakpoints')
    mapping(ui, enabled, 'breakpoints', (
        ('d', '删除断点', 'delete breakpoint'), ('<CR>', '跳到断点', 'jump to breakpoint'),
        ('<C-w><CR>', '强制跳转', 'force jump'),
        ('g?', '显示帮助', 'show help'), ('L', '变量', 'Scopes'),
        (']v', '前往下一个视图', 'go to next view'), ('[v', '前往上一个视图', 'go to prev view'),
        ('[V', '跳到第一个视图', 'jump to first view'), (']V', '跳到最后一个视图', 'jump to last view'),
    ))
    ui.send('W')
    capture(ui, 'watches-empty', tr(enabled, '暂无监视表达式', 'No expressions'))
    for section in ('threads', 'scopes', 'exceptions', 'sessions', 'console'):
        open_view(ui, section)
        probe(ui, f'require("dap-view.state").current_section == "{section}"')
        capture(ui, section + '-no-session', no_session)
    for section, keys in {
        'scopes': (('<CR>', '展开或折叠', 'toggle'), ('[[', '跳到父节点', 'jump to parent'),
                   ('s', '设置值', 'set value')),
        'threads': (('t', '切换隐蔽栈帧显示', 'toggle subtle frames'), ('f', '筛选栈帧', 'filter frames'),
                    ('o', '反转筛选', 'invert filter'), ('<CR>', '跳到栈帧', 'jump to frame'),
                    ('<C-w><CR>', '强制跳转', 'force jump')),
        'watches': (('a', '追加表达式', 'append expression'), ('i', '插入表达式', 'insert expression'),
                    ('d', '删除表达式', 'delete expression'), ('e', '编辑表达式', 'edit expression'),
                    ('c', '复制值', 'copy value'), ('s', '设置值', 'set value')),
        'exceptions': (('<CR>', '切换筛选器', 'toggle filter'), ('s', '设置条件', 'set condition'),
                       ('x', '清除条件', 'clear condition')),
        'sessions': (('<CR>', '切换会话', 'switch session'),),
    }.items():
        open_view(ui, section)
        mapping(ui, enabled, section, keys)
    ui.command('DapViewHover! var')
    capture(ui, 'hover-no-session', no_session)
    probe(ui, 'vim.bo.filetype == "dap-view-hover" and vim.api.nvim_win_get_width(0) == vim.fn.strdisplaywidth(vim.fn.getline(1))')
    mapping(ui, enabled, 'hover', (('q', '关闭', 'close'), ('s', '设置值', 'set value')))
    ui.send('q')
    for mode, section, chinese, english in (
        ('running', 'threads', '没有暂停的线程', 'No stopped thread'),
        ('running', 'scopes', '程序尚未暂停', 'Session not stopped'),
        ('no_scopes', 'scopes', '当前栈帧没有作用域', 'No scopes for the current frame'),
        ('expensive', 'scopes', '调试适配器未返回可显示的作用域', 'No eligible scopes returned from adapter'),
        ('no_variables', 'scopes', '调试适配器未返回变量', 'No variables returned from adapter'),
        ('no_threads', 'threads', '调试适配器未返回线程', 'Debug adapter returned no threads'),
        ('no_exceptions', 'exceptions', '调试适配器不支持此功能', 'Not supported by the debug adapter'),
        ('wrong_adapter', 'console', '当前会话没有终端', 'No terminal for the current session'),
    ):
        fixture(ui, mode)
        open_view(ui, section)
        capture(ui, mode + '-' + section, tr(enabled, chinese, english))
    open_view(ui, 'scopes')
    capture(ui, 'same-name-dap-data', 'Local', 'General Purpose Registers = No active session')
    open_view(ui, 'sessions')
    capture(ui, 'session-names', '1: No active session', '2: Local')
    ui.send('G\r')
    probe(ui, 'require("dap").session().id == 2')
    fixture(ui, 'off')
    open_view(ui, 'repl')
    capture(ui, 'repl', 'dap>')
    ui.send('i.help\r')
    capture(ui, 'repl-help', 'Custom commands:', 'dap>')
    ui.send(b'\x1b')
    open_view(ui, 'scopes')
    ui.resize(25, 52)
    capture(ui, 'narrow', '<', titles[-1], no_session)
    ui.send('L')
    probe(ui, 'require("dap-view.state").current_section == "scopes" and vim.fn.col(".") == 1 ')
    row, col = ui.screen.cursor()
    assert 0 <= row < 25 and 0 <= col < 52
    fixture(ui, 'stopped')
    ui.command('DapViewClose')
    ui.command('edit virtual.c')
    ui.command('setfiletype c')
    capture(ui, 'virtual-source', 'counter = 7', 'virtual.c')
    lua(ui, '''
      vim.treesitter.query.set("c", "locals", "(init_declarator declarator: (identifier) @local.definition)");
      local f=DvSession.current_frame; f.source.path=vim.fn.expand("%:p"); f.line=2;
      f.scopes[1].variables={{name="counter",value="No active session",type="string",variablesReference=0}};
    '''.replace('\n', ' '))
    ui.command('DapViewVirtualTextEnable')
    capture(ui, 'virtual-text', 'counter No active session = 7')
    ui.command('DapViewVirtualTextDisable')
    capture(ui, 'virtual-text-disabled', 'counter = 7', reject=('counter No active session',))


def choose(ui, enabled, *, select, name):
    ui.send(b'\x17\r')
    new_tab = tr(enabled, '新建标签页', 'newtab')
    screen = capture(ui, name, tr(enabled, '选择跳转方式：', 'Specify jump behavior:'), new_tab,
                     tr(enabled, '使用上一个 Window', 'uselast'),
                     tr(enabled, '使用当前标签页已打开的 Window', 'useopen'),
                     tr(enabled, '在所有标签页查找已打开的 Window', 'usetab'),
                     tr(enabled, '自定义', 'custom'))
    if select:
        number = re.search(r'(\d+): ' + new_tab, screen)[1]
        ui.send(number + '\r')
    else:
        ui.send('0\r')


def interaction(ui, enabled):
    ui.command('edit main.cpp')
    ui.command('8')
    lua(ui, 'require("dap").toggle_breakpoint()')
    lua(ui, 'DvSetup({switchbuf = function(buf) DvEvents.switchbuf = buf; return vim.fn.bufwinid(buf) end})')
    fixture(ui, 'stopped')
    ui.command('DapViewOpen')
    open_view(ui, 'watches')
    expr = tr(enabled, '表达式：', 'Expression:')
    value = tr(enabled, '新值：', 'New value:')
    ui.send('a')
    capture(ui, 'add-watch', expr)
    ui.send(b'\x1b')
    capture(ui, 'watch-cancel', tr(enabled, '暂无监视表达式', 'No expressions'), reject=(expr,))
    ui.send('aAns\t')
    capture(ui, 'watch-completion-first', expr + ' Another', 'Answer')
    ui.send('\t')
    capture(ui, 'watch-completion', expr + ' Answer')
    ui.send('\r')
    capture(ui, 'watch-evaluate', 'Answer = eval:Answer')
    probe(ui, 'DvEvents.evaluate.expression == "Answer" and DvEvents.completions.text == "Ans"')
    ui.send('e')
    capture(ui, 'watch-edit-default', expr + ' Answer')
    ui.send(b'\x15Local\r')
    capture(ui, 'watch-edit-result', 'Local = eval:Local')
    ui.send('s')
    capture(ui, 'watch-value', value + ' eval:Local')
    ui.send(b'\x15No active session\r')
    probe(ui, 'DvEvents.setExpression.expression == "Local" and DvEvents.setExpression.value == "No active session"')

    open_view(ui, 'scopes')
    ui.send('Gs')
    capture(ui, 'scope-value-default', value + ' No active session')
    ui.send(b'\x1b')
    probe(ui, 'DvEvents.setVariable == nil')
    ui.send('s')
    capture(ui, 'scope-value-submit', value + ' No active session')
    ui.send(b'\x1521\r')
    capture(ui, 'scope-after-set', 'General Purpose Registers = 21')
    probe(ui, 'DvEvents.setVariable.name == "General Purpose Registers" and DvEvents.setVariable.variablesReference == 100')

    ui.command('DapViewHover! Local')
    capture(ui, 'hover', 'eval:Local')
    ui.send('s')
    capture(ui, 'hover-set-value', value + ' eval:Local')
    ui.send(b'\x1b')
    ui.send('s')
    capture(ui, 'hover-set-after-cancel', value + ' eval:Local')
    ui.send(b'\x1532\r')
    probe(ui, 'DvEvents.setExpression.expression == "Local" and DvEvents.setExpression.value == "32"')
    ui.send('q')

    open_view(ui, 'threads')
    filter_text = tr(enabled, '筛选：', 'Filter:')
    ui.send('f')
    capture(ui, 'filter-frames', filter_text)
    ui.send('Local\r')
    capture(ui, 'frame-filtered', 'fixture thread', 'Local', reject=('No active session main.cpp',))
    ui.send('f')
    capture(ui, 'filter-default', filter_text + ' Local')
    ui.send(b'\x1b')
    probe(ui, 'require("dap-view.state").threads_filter == "Local"')
    ui.send('f\x15\r')
    capture(ui, 'threads-clear-filter', 'No active session', 'main.cpp:8')
    ui.send('gg2j')
    choose(ui, enabled, select=False, name='force-frame-cancel')
    probe(ui, '#vim.api.nvim_list_tabpages() == 1 and DvEvents.frame == nil')
    choose(ui, enabled, select=True, name='force-frame-select')
    probe(ui, '#vim.api.nvim_list_tabpages() == 2 and DvEvents.frame == 12 and vim.fn.line(".") == 8')
    ui.command('tabclose')

    fixture(ui, 'multiple_threads')
    open_view(ui, 'threads')
    capture(ui, 'multiple-threads', 'fixture thread', 'worker No active session', 'worker_frame main.cpp:9')
    click(ui, 'worker_frame main.cpp:9')
    ui.send('\r')
    probe(ui, 'DvEvents.frame == 21 and vim.fn.line(".") == 9 and DvEvents.switchbuf == vim.api.nvim_get_current_buf()')

    open_view(ui, 'exceptions')
    cond = tr(enabled, '条件：', 'Condition:')
    ui.send('ggs')
    capture(ui, 'exception-condition', cond)
    ui.send('No active session\r')
    capture(ui, 'exception-example', tr(enabled, '示例：No active session', 'Example: No active session'),
            'C++: on throw')
    probe(ui, 'DvEvents.setExceptionBreakpoints.filterOptions[1].filterId == "cpp_throw" and '
          'DvEvents.setExceptionBreakpoints.filterOptions[1].condition == "No active session"')
    ui.send('s')
    capture(ui, 'exception-default', cond + ' No active session')
    ui.send(b'\x1b')
    ui.send('x')
    probe(ui, '#DvEvents.setExceptionBreakpoints.filterOptions == 0')

    open_view(ui, 'breakpoints')
    capture(ui, 'breakpoint-line', 'vec_int.emplace_back(i);')
    choose(ui, enabled, select=False, name='force-breakpoint-cancel')
    probe(ui, '#vim.api.nvim_list_tabpages() == 1 and vim.bo.filetype == "dap-view"')
    choose(ui, enabled, select=True, name='force-breakpoint-select')
    probe(ui, '#vim.api.nvim_list_tabpages() == 2 and vim.fn.line(".") == 8')

    lua(ui, 'vim.ui.input({prompt = "Expression: ", default = "Local"}, function(v) DvForeignInput = v end)')
    capture(ui, 'foreign-input', 'Expression: Local')
    ui.send('\r')
    probe(ui, 'DvForeignInput == "Local"')
    lua(ui, 'vim.ui.select({"newtab"}, {prompt="Specify jump behavior: "}, function(v,i) DvForeignChoice={v,i} end)')
    capture(ui, 'foreign-selector', 'Specify jump behavior:', '1: newtab')
    ui.send('1\r')
    probe(ui, 'DvForeignChoice[1] == "newtab" and DvForeignChoice[2] == 1')

    ui.command('tabclose')
    open_view(ui, 'scopes')
    ui.send('g?')
    title = tr(enabled, '默认按键', 'Default Keymaps')
    capture(ui, 'key-help', title, tr(enabled, '变量', 'Scopes'), '<CR>', '[[',
            '<C-w><CR>', tr(enabled, '展开或折叠变量', 'Expand or collapse a variable'))
    ui.send('G')
    capture(ui, 'key-help-navigation', title, ']v', '[v', '[V', ']V', tr(enabled, '关闭', 'Close'))
    ui.command('nmap <buffer> q')
    capture(ui, 'mapping-key-help-q', 'n  q', tr(enabled, '关闭', 'close'))
    dismiss_error(ui)
    probe(ui, 'vim.bo.filetype == "dap-view-help"')
    ui.send('q')
    capture(ui, 'key-help-closed', tr(enabled, '变量 [L]', 'Scopes [L]'), reject=(title,))
    ui.resize(22, 49)
    ui.send('g?')
    capture(ui, 'key-help-narrow', title, '<CR>')
    ui.send('G')
    capture(ui, 'key-help-narrow-end', title, ']V')
    ui.send('q')
    probe(ui, 'vim.bo.filetype == "dap-view"')
    ui.command('set winborder=')
    ui.send('g?')
    if enabled:
        capture(ui, 'key-help-default-border', title, '展开或折叠变量')
    else:
        capture(ui, 'key-help-default-border', 'Expand or', reject=(title,))
    ui.send('q')
    probe(ui, 'vim.bo.filetype == "dap-view"')


def diagnostics(ui, enabled):
    def notice(name, action, chinese, english, level=None):
        lua(ui, action)
        text = tr(enabled, chinese, english)
        capture(ui, name, text)
        dismiss_error(ui)
        if level:
            probe(ui, f'DvNotices[#DvNotices].level == vim.log.levels.{level}')

    notice('jump-unconfigured', 'vim.cmd.DapViewJump("absent")',
           '无法跳到未配置的视图：absent', "Can't jump to unconfigured view: absent")
    notice('show-unconfigured', 'vim.cmd.DapViewShow("absent")',
           '无法显示未配置的视图：absent', "Can't show unconfigured view: absent")
    notice('jump-closed', 'vim.cmd.DapViewJump("scopes")',
           '无法跳到视图：找不到 Window', "Can't jump to view: couldn't find the window")
    notice('show-closed', 'vim.cmd.DapViewShow("scopes")',
           '无法显示视图：找不到 Window', "Can't show view: couldn't find the window")
    notice('navigate-closed', 'vim.cmd.DapViewNavigate("1")',
           '无法在视图间导航：找不到 Window', "Can't navigate within views: couldn't find the window")
    notice('navigate-sessions', 'require("dap-view").navigate({count=1,type="sessions",wrap=true})',
           '无法在会话间导航：当前没有运行的会话', "Can't navigate within sessions: no session running")
    notice('guard-no-session', 'require("dap-view.guard").expect_stopped()', *NO_ACTIVE)
    lua(ui, 'vim.notify("No active session")')
    capture(ui, 'foreign-notice', 'No active session')

    ui.command('edit main.cpp')
    ui.command('DapViewOpen')
    notice('navigate-missing-object', 'local s=require("dap-view.state"); local current=s.current_section; '
           's.current_section="missing"; vim.cmd.DapViewNavigate("1"); s.current_section=current',
           '无法导航：找不到当前位置对应的对象', "Can't navigate: couldn't find the current object")
    notice('missing-view-once', 'require("dap-view.options.winbar").wrapped_action("absent")',
           '找不到视图「absent」', "View 'absent' not found", 'WARN')
    probe(ui, '''(function()
      local before = #DvNotices
      require("dap-view.options.winbar").wrapped_action("absent")
      assert(not vim.notify_once("View 'absent' not found", vim.log.levels.WARN))
      return #DvNotices == before
    end)()'''.replace('\n', ' '))
    lua(ui, 'DvSetup({winbar={sections={"scopes","not_configured"}, default_section="scopes"}})')
    notice('missing-view-setup', 'vim.cmd.DapViewOpen()',
           '找不到视图「not_configured」，跳过设置', "View 'not_configured' not found, skipping setup", 'WARN')
    lua(ui, 'DvSetup({winbar={sections={"scopes","broken"}, custom_sections={broken={'
            'label="broken", keymap="M", buffer=function() return -1 end, action=function() DvCustom=true end}}}})')
    ui.command('DapViewJump broken')
    capture(ui, 'bad-custom-buffer', tr(enabled, '无法设置 broken 视图的 Buffer', "Couldn't set the buffer for broken view"))
    dismiss_error(ui)
    probe(ui, 'DvNotices[#DvNotices].level == vim.log.levels.ERROR')
    lua(ui, 'DvSetup(); vim.cmd.DapViewOpen()')

    fixture(ui, 'running')
    notice('guard-running', 'require("dap-view.guard").expect_stopped()', '没有暂停的线程', 'No stopped thread')
    fixture(ui, 'stopped')
    open_view(ui, 'threads')
    ui.send('gg\r')
    capture(ui, 'jump-thread-not-frame', tr(enabled, '只能跳到栈帧', 'Can only jump to a frame'))
    probe(ui, 'DvNotices[#DvNotices].level == vim.log.levels.INFO')
    fixture(ui, 'missing_file')
    ui.send('ggj\r')
    capture(ui, 'missing-file', tr(enabled, '找不到文件：', 'File not found: ') + '/invalid/No active session.cpp')
    dismiss_error(ui)
    probe(ui, 'DvNotices[#DvNotices].level == vim.log.levels.ERROR')
    lua(ui, 'require("dap-view.state").threads_error="No stopped thread"')
    open_view(ui, 'threads')
    capture(ui, 'dap-error-body', 'No stopped thread', reject=('没有暂停的线程',))
    lua(ui, 'require("dap-view.state").threads_error=nil')

    open_view(ui, 'exceptions')
    ui.send('Gs')
    capture(ui, 'condition-unsupported', tr(enabled, '不支持条件', 'Condition not supported'))
    ui.send('x')
    capture(ui, 'clear-condition-unsupported', tr(enabled, '不支持条件', 'Condition not supported'))

    open_view(ui, 'watches')
    ui.send('d')
    capture(ui, 'delete-missing-watch', tr(enabled, '光标下没有表达式', 'No expression under the under cursor'))
    ui.send('c')
    capture(ui, 'copy-missing-watch', tr(enabled, '光标下没有表达式或变量', 'No expression or variable under the under cursor'))
    ui.send('s\r')
    capture(ui, 'set-missing-watch', tr(enabled, '光标下没有表达式或变量', 'No expression or variable under the under cursor'))
    ui.send('\r')
    capture(ui, 'toggle-missing-watch', tr(enabled, '光标下没有表达式或变量', 'No expression or variable under the under cursor'))
    lua(ui, 'DvCompletionError = true')
    ui.send('aAns\t')
    ui.send(b'\x1b')
    ui.command('messages')
    capture(ui, 'completion-failure', tr(enabled, '补全请求失败：No active session',
                                        'completions request failed: No active session'))
    probe(ui, 'DvNotices[#DvNotices].level == vim.log.levels.WARN')
    ui.command('DapViewWatch Local')
    ui.send('c')
    capture(ui, 'clipboard-unsupported', tr(enabled, '调试适配器不支持为剪贴板求值',
                                           "Adapter doesn't support clipboard evaluation"))
    lua(ui, 'DvSession.capabilities.supportsClipboardContext=true; vim.g.clipboard={name="fixture",'
            'copy={["+"]=function(lines) DvEvents.clipboard=lines[1] end, ["*"]=function() end},'
            'paste={["+"]=function() return {{}, "v"} end, ["*"]=function() return {{}, "v"} end}}')
    ui.send('c')
    capture(ui, 'clipboard-copy', tr(enabled, '已将变量 Local 复制到剪贴板', 'Variable Local copied to clipboard'))
    probe(ui, 'DvEvents.evaluate.context == "clipboard" and DvEvents.clipboard == "No active session"')
    ui.command('DapViewWatch Tree')
    capture(ui, 'watch-tree', 'Tree = tree', 'General Purpose Registers = No active session')
    click(ui, 'General Purpose Registers = No active session')
    ui.send('c')
    capture(ui, 'watch-copy-missing-reference', tr(enabled, '缺少 `evaluateName`，无法复制变量',
                                                   "Missing `evaluateName`, can't copy variable"))
    ui.send('\r')
    capture(ui, 'watch-nothing-to-expand', tr(enabled, '没有可展开的内容', 'Nothing to expand'))

    open_view(ui, 'scopes')
    lua(ui, 'DvSetError=true; DvSetDeferred=true')
    ui.send('Gs\x15value% data\r')
    capture(ui, 'async-set-variable-failure', tr(enabled, '无法将变量 General Purpose Registers 的值设为 value% data',
                                                'Failed to set variable General Purpose Registers to value value% data'))
    probe(ui, 'DvEvents.setVariable.name == "General Purpose Registers" and DvEvents.setVariable.value == "value% data"')
    ui.command('DapViewHover! Local')
    ui.send('s\x15%expr\r')
    capture(ui, 'async-set-expression-failure', tr(enabled, '无法将表达式 Local 的值设为 %expr',
                                                  'Failed to set expression Local to value %expr'))
    ui.send('q')
    lua(ui, 'DvSession.capabilities.supportsSetVariable=false')
    ui.send('Gs\r')
    capture(ui, 'missing-evaluate-name', tr(enabled, '无法设置 General Purpose Registers 的值，缺少 `evaluateName`',
                                          "Can't set value for General Purpose Registers because it lacks an `evaluateName`"))
    lua(ui, 'DvSession.capabilities.supportsSetExpression=false')
    ui.send('Gs\r')
    capture(ui, 'set-capabilities-missing', tr(enabled, '调试适配器不支持 `setExpression` 和 `setVariable` 请求',
                                              'Adapter lacks support for both `setExpression` and `setVariable` requests'))
    notice('set-expression-unsupported', 'require("dap-view.views.set").set_expr("Local", "x")',
           '调试适配器不支持 `setExpression` 请求', "Adapter doesn't support `setExpression` request")
    notice('set-variable-unsupported', 'local calls=0; setmetatable(DvSession.capabilities,{__index=function(t,k) '
           'if k=="supportsSetVariable" then calls=calls+1; return calls==1 end end}); '
           'DvSession.capabilities.supportsSetVariable=nil; require("dap-view.views.set").set_value(100,"Local","x"); '
           'setmetatable(DvSession.capabilities,nil)',
           '调试适配器不支持 `setVariable` 请求', "Adapter doesn't support `setVariable` request")
    notice('scope-nothing-to-expand', 'require("dap-view.scopes.actions").expand_or_collapse(900)',
           '没有可展开的内容', 'Nothing to expand')
    notice('hover-nothing-to-expand', 'require("dap-view.hover.actions").expand_or_collapse(900)',
           '没有可展开的内容', 'Nothing to expand')
    notice('session-missing', 'require("dap-view.sessions.actions").switch_to_session(900)',
           '光标下没有会话', 'No session under the cursor')

    def config_error(name, options, chinese, english, *data):
        lua(ui, 'local ok, err=pcall(require("dap-view").setup,' + options
            + '); assert(not ok); vim.api.nvim_echo({{err}}, false, {})')
        capture(ui, name, tr(enabled, chinese, english), *data)
        dismiss_error(ui)

    # Upstream merges before validation, so repair the exact failed fields before
    # progressing to the next independent invalid input.
    config_error('unknown-auto-toggle', '{auto_toggle="bad_mode"}',
                 '未知的 auto_toggle 选项：', 'Unknown auto_toggle option:', 'bad_mode', 'validate/init.lua:23')
    lua(ui, 'require("dap-view.setup").config.auto_toggle=false')
    ui.resize(46, 185)
    probe(ui, 'vim.wait(1000, function() return vim.o.columns == 185 end)')
    config_error('field-type', '{windows={size="bad_size"}}',
                 'windows.size：应为 number|function，实际为 string',
                 'size: expected number|function, got string', 'windows.', 'validate/util.lua:23', 'validate/util.lua:11')
    lua(ui, 'require("dap-view.setup").config.windows.size=0.4')
    config_error('unknown-field', '{windows={extra_key=123}}',
                 'windows.extra_key：配置含有未知字段', 'windows.extra_key: unexpected field found in configuration',
                 'validate/util.lua:29')
    lua(ui, 'require("dap-view.setup").config.windows.extra_key=nil')
    config_error('unknown-default', '{winbar={default_section="absent"}}',
                 '默认分区（absent）不在分区列表', 'Default section (absent) not listed as one of the sections',
                 'validate/winbar.lua:91')
    lua(ui, 'require("dap-view.setup").config.winbar.default_section="scopes"')
    config_error('empty-sections', '{winbar={sections={}}}', '至少需要一个分区',
                 'There must be at least one section', 'validate/winbar.lua:84')
    lua(ui, 'DvSetup()')
    config_error('too-many-separators', '{winbar={separators={"a","b","c"}}}',
                 'separators 表最多包含 2 个元素', 'Separators table must contain at most 2 elements',
                 'validate/winbar.lua:87')
    lua(ui, 'require("dap-view.setup").config.winbar.separators=nil')
    lua(ui, 'DvSession.capabilities.supportsSetExpression=true; DvDisableDuringSet=true; '
            'require("dap-view.views.set").set_expr("Local", "after-disable")')
    capture(ui, 'stale-delayed-notice', 'Failed to set expression Local to value after-disable',
            reject=('无法将表达式 Local 的值设为 after-disable',))
    lua(ui, 'require("nvim-zh").setup({modules={core={enabled=false},plugins={auto=' +
        str(enabled).lower() + '}}})')
    ui.command('DapViewClose')
    fixture(ui, 'off')

    def upstream_error(name, action, chinese, english, source):
        lua(ui, action + '; assert(not ok); print(err)')
        capture(ui, name, tr(enabled, chinese, english), source)
        dismiss_error(ui)

    upstream_error('assert-view-window',
                   'local ok,err=pcall(require("dap-view.views").cleanup_view,true,"foreign")',
                   '应有 nvim-dap-view Window', 'has nvim-dap-view window', 'views/init.lua:12')
    upstream_error('assert-view-buffer',
                   'local s=require("dap-view.state"); s.winnr=vim.api.nvim_get_current_win(); '
                   'local ok,err=pcall(require("dap-view.views").cleanup_view,true,"foreign"); s.winnr=nil',
                   '应有 nvim-dap-view Buffer', 'has nvim-dap-view buffer', 'views/init.lua:13')
    upstream_error('assert-hover-session',
                   'local ok,err=pcall(require("dap-view.hover.eval").evaluate_expression,"Local")',
                   '应有活动调试会话', 'has active session', 'hover/eval.lua:13')
    upstream_error('assert-hover-expression',
                   'local ok,err=pcall(require("dap-view.hover.view").show,0)',
                   '应有悬浮求值表达式', 'has hover', 'hover/view.lua:105')
    upstream_error('assert-hover-state',
                   'local s=require("dap-view.state"); s.hover="Local"; '
                   'local ok,err=pcall(require("dap-view.hover.view").show,0); s.hover=nil',
                   '应有悬浮求值状态', 'has hover state', 'hover/view.lua:106')
    for method, label, line in (('nvim_create_buf', 'Buffer', 68), ('nvim_open_win', 'Window', 145)):
        upstream_error('assert-create-' + label.lower(),
                       f'local api=vim.api; local old=api.{method}; api.{method}=function() return 0 end; '
                       f'local ok,err=pcall(require("dap-view").open); api.{method}=old',
                       '无法创建 nvim-dap-view ' + label,
                       'Failed to create nvim-dap-view ' + label.lower(), f'actions.lua:{line}')
        ui.command('DapViewClose')

    fixture(ui, 'stopped')
    lua(ui, 'DvSetup({render={threads={format=function() return {{text="raw",separator="xx"}} end}}})')
    ui.command('DapViewOpen')
    upstream_error('assert-thread-separator',
                   'local ok,err=pcall(require("dap-view.threads.view").show)',
                   '分隔符长度最多为 1 个字符', 'Separator length must not exceeed 1 character', 'threads/view.lua:158')
    lua(ui, 'DvSetup({render={breakpoints={format=function() return {{text="raw",separator="xx"}} end}}}); '
            'require("dap").toggle_breakpoint()')
    upstream_error('assert-breakpoint-separator',
                   'local ok,err=pcall(require("dap-view.breakpoints.view").show)',
                   '分隔符长度最多为 1 个字符', 'Separator length must not exceeed 1 character', 'breakpoints/view.lua:54')
    upstream_error('assert-virtual-text-frame',
                   'local frame=DvSession.current_frame; DvSession.current_frame=nil; local reads=0; '
                   'setmetatable(DvSession,{__index=function(_,key) if key=="current_frame" then '
                   'reads=reads+1; if reads<=5 then return frame end end end}); '
                   'local ok,err=pcall(vim.cmd.DapViewVirtualTextEnable); '
                   'setmetatable(DvSession,nil); DvSession.current_frame=frame',
                   '应有栈帧', 'has frame', 'virtual-text.lua:74')


def help_topics(ui, enabled):
    upstream = (Path(os.environ[DEPS[-1]]) / 'doc/dap-view.txt').read_text(encoding='utf-8')
    translated = (Path(os.environ['NVIM_ZH_ROOT']) /
                  'translations/help/adapters/nvim-dap-view/dap-view.cnx').read_text(encoding='utf-8')
    assert Counter(tags(upstream)) == Counter(tags(translated))
    assert links(upstream) == links(translated)
    assert [block.strip('\n') for block in example_blocks(upstream)] == [
        block.strip('\n') for block in example_blocks(translated)]
    headings = {
        'features': ('功能特性', 'FEATURES'), 'configuration': ('配置', 'CONFIGURATION'),
        'keymaps': ('映射', 'KEYMAPS'), 'commands': ('命令', 'COMMANDS'), 'api': ('API', 'API'),
        'filetypes': ('文件类型', 'FILETYPES'), 'completion': ('补全', 'COMPLETION'),
        'faq': ('常见问题', 'FAQ'), 'highlight-groups': ('高亮组', 'HIGHLIGHT GROUPS'),
        'control-bar': ('控制栏', 'CONTROL BAR'), 'custom-formatting': ('自定义格式化', 'CUSTOM FORMATTING'),
        'custom-views': ('自定义视图', 'CUSTOM VIEWS'), 'switchbuf': ('高级 switchbuf', 'ADVANCED SWITCHBUF'),
        'dynamic-layout': ('动态布局', 'DYNAMIC LAYOUT'), 'restoring-sessions': ('恢复会话', 'RESTORING SESSIONS'),
    }
    ui.command('help dap-view.txt')
    capture(ui, 'main-help', tr(enabled, 'nvim-dap-view 是 nvim-dap 的调试界面', 'nvim-dap-view is a UI for nvim-dap.'))
    probe(ui, 'vim.bo.buftype == "help" and vim.fn.expand("%:e") == "' + tr(enabled, 'cnx', 'txt') + '"')
    for tag, (chinese, english) in headings.items():
        ui.command('help dap-view-' + tag)
        capture(ui, 'help-' + tag, tr(enabled, chinese, english), 'dap-view-' + tag)
    ui.send(b'\x1d')
    probe(ui, 'vim.bo.buftype == "help"')


def lifecycle(ui, enabled):
    # This plugin has already run setup after explicit source registration,
    # including in the disabled launch where source evidence is still retained.
    title = tr(enabled, '变量 [L]', 'Scopes [L]')
    ui.command('DapViewOpen')
    capture(ui, 'first-open', title, tr(enabled, *NO_ACTIVE))
    lua(ui, 'DvRefresh=require("dap-view.options.winbar").set_winbar_opt; DvSetup(); require("nvim-zh").refresh()')
    open_view(ui, 'scopes')
    capture(ui, 'repeated-setup', title)
    probe(ui, 'DvRefresh == require("dap-view.options.winbar").set_winbar_opt')
    lua(ui, 'require("nvim-zh").setup({modules={core={enabled=false},plugins={disabled={"nvim-dap-view"}}}})')
    ui.command('DapViewOpen')
    capture(ui, 'disabled', 'Scopes [L]', 'No active session')
    lua(ui, 'require("nvim-zh").setup({modules={core={enabled=false},plugins={auto=true}}})')
    ui.command('DapViewOpen')
    capture(ui, 'late-enabled', '变量 [L]', '无活动调试会话')
    lua(ui, 'DvSetup({winbar={show_keymap_hints=false, base_sections={scopes={label="Scopes"},'
            'threads={label=function(width, section) DvWidth=width; DvSection=section; return "Threads" end}},'
            'sections={"scopes","threads","breakpoints","custom"}, custom_sections={custom={label="Watches",'
            'keymap="M",buffer=function() local b=vim.api.nvim_create_buf(false,true); '
            'vim.api.nvim_buf_set_lines(b,0,-1,false,{"custom payload"}); return b end,'
            'action=function() DvCustom=true end}}}}); vim.cmd.DapViewOpen()')
    capture(ui, 'custom-labels', 'Scopes', 'Threads', '断点', 'Watches', reject=('[L]', '[T]', '[B]', '[M]'))
    click(ui, 'Watches')
    capture(ui, 'custom-click', 'custom payload')
    probe(ui, 'DvCustom and DvWidth > 0 and DvSection == "custom"')
    lua(ui, 'DvOverride=function() vim.wo[require("dap-view.state").winnr].winbar="EXTERNAL WINBAR" end; '
            'require("dap-view.options.winbar").set_winbar_opt=DvOverride; require("nvim-zh").refresh()')
    open_view(ui, 'breakpoints')
    capture(ui, 'external-override', 'EXTERNAL WINBAR', '暂无断点')
    probe(ui, 'require("nvim-zh").status().adapters["nvim-dap-view"].surfaces.titles.status == "external_override"')
    lua(ui, 'require("dap-view.options.winbar").set_winbar_opt=DvRefresh; require("nvim-zh").teardown()')
    ui.command('DapViewOpen')
    open_view(ui, 'breakpoints')
    capture(ui, 'teardown', 'Breakpoints', 'No breakpoints', reject=('暂无断点',))


def unverified(ui, enabled, mismatch):
    ui.command('DapViewOpen')
    capture(ui, 'english-fallback', 'Scopes [L]', tr(enabled and mismatch, *NO_ACTIVE), reject=('变量 [L]',))
    if enabled:
        reason = 'unsupported_revision' if mismatch else 'unknown_version'
        probe(ui, 'require("nvim-zh").status().adapters["nvim-dap-view"].surfaces.titles.status == "' + reason + '"')


REAL_SETUP = """
local dap = require('dap')
dap.adapters.codelldb = { type = 'executable', command = 'codelldb' }
dap.configurations.cpp = {{
  name = '调试 C++ 程序', type = 'codelldb', request = 'launch',
  cwd = '${workspaceFolder}', terminal = 'integrated',
  program = function()
    local path = vim.fn.input('可执行文件: ', './main', 'file')
    return path == '' and dap.ABORT or vim.fn.fnamemodify(path, ':p')
  end,
}}
DvSetup({auto_toggle = 'keep_terminal'})
vim.keymap.set('n', '<F5>', dap.continue, { desc = '开始 / 继续调试' })
vim.keymap.set('n', '<F8>', dap.toggle_breakpoint, { desc = '切换断点' })
vim.keymap.set('n', '<F10>', dap.step_over, { desc = '单步跳过' })
"""
REAL_OPTIONS = """
DvSetup({auto_toggle = 'keep_terminal',
  winbar = { sections = {'scopes','threads','breakpoints','watches','exceptions','sessions','repl'} },
  windows = { terminal = { size = 0.28 } },
})
DvRealRequests = {}
local dap = require('dap')
for _, name in ipairs({'evaluate','setVariable','setExceptionBreakpoints'}) do
  dap.listeners.before[name].zh_tui_test = function(_, _, _, request)
    DvRealRequests[name] = request
  end
end
dap.listeners.after.event_exited.zh_tui_test = function(_, body)
  DvExitCode = body.exitCode
end
vim.api.nvim_create_user_command('DvFocusSource', function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match('/main%.cpp$') then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  error('source window absent')
end, {})
"""


def real_setup():
    supplied = os.environ.get('NVIM_ZH_DAP_VIEW_INIT')
    if not supplied:
        return REAL_SETUP + REAL_OPTIONS
    # Reuse the supplied init's launch configuration and F-keys. The harness
    # supplies the same fixed plugin trees and controls the language switch.
    text = Path(supplied).read_text(encoding='utf-8')
    text, pack_count = re.subn(r'(?ms)^vim\.pack\.add\(\{.*?^\}, \{ load = true \}\)\n', '', text)
    text, setup_count = re.subn(r"(?ms)^require\('nvim-zh'\)\.setup\(\{.*?^\}\)\n", '', text)
    assert pack_count == setup_count == 1, 'expected the supplied vim.pack and nvim-zh setup blocks'
    return text + REAL_OPTIONS


def codelldb(ui, enabled):
    subprocess.run(['g++', '-g', '-O0', 'main.cpp', '-o', 'main'], cwd=ui.cwd, check=True, timeout=30)
    ui.command('edit main.cpp')
    ui.command('8')
    ui.send(F8)
    probe(ui, 'next(require("dap.breakpoints").get()) ~= nil')
    ui.send(F5)
    capture(ui, 'launch', '可执行文件: ./main')
    ui.send('\r')
    scope_title = tr(enabled, '变量 [L]', 'Scopes [L]')
    local = tr(enabled, '局部', 'Local')
    registers = tr(enabled, '寄存器', 'Registers')
    capture(ui, 'first-frame', scope_title, 'vec_int = size=0', local, tr(enabled, '静态', 'Static'),
            tr(enabled, '全局', 'Global'), registers, timeout=15)
    probe(ui, '''(function()
      local s = require("dap").session()
      assert(s.config.type == "codelldb" and s.current_frame.line == 8)
      local names = {}
      for _, scope in ipairs(s.current_frame.scopes) do
        assert(scope.presentationHint == nil)
        names[#names+1] = scope.name
      end
      return table.concat(names, ",") == "Local,Static,Global,Registers"
    end)()'''.replace('\n', ' '))
    output = capture(ui, 'program-terminal', '\nTest 1', timeout=10)
    assert re.search(r'^Test 1\s*', output, re.MULTILINE)
    probe(ui, 'vim.api.nvim_buf_get_lines(require("dap").session().term_buf,0,-1,false)[1] == "Test 1"')
    lua(ui, 'vim.api.nvim_set_current_win(require("dap-view.state").term_winnr)')
    mapping(ui, enabled, 'console', ((']s', '前往下一个会话', 'go to next session'),
                                     ('[s', '前往上一个会话', 'go to prev session')))
    ui.send(']s')
    probe(ui, 'vim.bo.filetype == "dap-view-term" and require("dap").session().term_buf == vim.api.nvim_get_current_buf()')

    open_view(ui, 'scopes')
    ui.send('gg\r')
    capture(ui, 'scope-collapse', scope_title, local, registers, reject=('vec_int = size=0',))
    probe(ui, 'vim.tbl_contains(require("dap-view.state").collapsed_scopes, "Local")')
    ui.send('gg\r')
    capture(ui, 'scope-expand', 'vec_int = size=0')
    capture(ui, 'register-groups', tr(enabled, '通用寄存器', 'General Purpose Registers'),
            tr(enabled, '浮点寄存器', 'Floating Point Registers'),
            tr(enabled, '高级向量扩展', 'Advanced Vector Extensions'))
    register_group = tr(enabled, '通用寄存器', 'General Purpose Registers')
    click(ui, register_group)
    ui.send('\r')
    capture(ui, 'register-expand', 'rax = ', 'rbx = ')
    probe(ui, 'vim.tbl_contains(vim.tbl_values(require("dap-view.state").variable_path_to_name), "General Purpose Registers")')
    click(ui, register_group)
    ui.send('\r')
    capture(ui, 'register-collapse', 'vec_int = size=0', reject=('rax = ',))

    ui.command('DvFocusSource')
    ui.send(F10)
    capture(ui, 'step-over', 'vec_int = size=1', timeout=10)
    click(ui, 'vec_int = size=1')
    probe(ui, 'vim.bo.filetype == "dap-view" and vim.fn.getline("."):find("vec_int = size=1", 1, true)')
    ui.send('\r')
    capture(ui, 'vector-expand', 'vec_int = size=1', '[0] = 0')
    # Editing the vector element uses the original name and reference.
    click(ui, '[0] = 0')
    ui.send('s')
    value = tr(enabled, '新值：', 'New value:')
    capture(ui, 'real-variable-input', value + ' 0')
    ui.send(b'\x1542\r')
    capture(ui, 'real-variable-set', '[0] = 42', timeout=10)
    probe(ui, 'DvRealRequests.setVariable.name == "[0]" and DvRealRequests.setVariable.value == "42" '
          'and DvRealRequests.setVariable.variablesReference > 0')

    open_view(ui, 'threads')
    capture(ui, 'threads', 'main.cpp:', 'main')
    ui.send('ggj\r')
    probe(ui, 'vim.fn.expand("%:t") == "main.cpp" and require("dap").session().current_frame.name:find("main", 1, true)')
    ui.command('DapViewWatch vec_int')
    open_view(ui, 'watches')
    capture(ui, 'real-watch', 'vec_int = size=1', '[0] = 42')
    open_view(ui, 'threads')
    capture(ui, 'before-hover', 'main.cpp:', reject=('vec_int = size=1',))
    ui.command('DvFocusSource')
    ui.command('DapViewHover! vec_int')
    capture(ui, 'real-hover', 'vec_int = size=1', '[0] = 42')
    ui.send('\r')
    capture(ui, 'real-hover-collapsed', 'vec_int = size=1', reject=('[0] = 42',))
    ui.send('\r')
    capture(ui, 'real-hover-expanded', '[0] = 42')
    probe(ui, 'vim.bo.filetype == "dap-view-hover" and DvRealRequests.evaluate.expression == "vec_int"')
    ui.send('q')
    ui.expect(reject=('[0] = 42',))

    open_view(ui, 'exceptions')
    capture(ui, 'exception-filters', tr(enabled, 'C++：抛出时', 'C++: on throw'),
            tr(enabled, 'C++：捕获时', 'C++: on catch'))
    ui.send('G\r')
    probe(ui, '''(function()
      local options = require("dap-view.state").exceptions_options.codelldb
      return options[1].exception_filter.filter == "cpp_throw" and options[2].exception_filter.filter == "cpp_catch"
        and options[2].enabled
    end)()'''.replace('\n', ' '))
    probe(ui, 'vim.wait(1000, function() return DvRealRequests.setExceptionBreakpoints and '
          'vim.tbl_contains(DvRealRequests.setExceptionBreakpoints.filters, "cpp_catch") end)')
    ui.send('s')
    capture(ui, 'real-exception-condition', tr(enabled, '条件：', 'Condition:'))
    ui.send(b'\x1b')
    ui.expect(reject=(tr(enabled, '条件：', 'Condition:'),))
    ui.send('\r')
    probe(ui, 'require("dap-view.state").exceptions_options.codelldb[2].enabled == false')

    ui.command('DvFocusSource')
    ui.command('8')
    ui.send(F8)
    open_view(ui, 'breakpoints')
    capture(ui, 'breakpoint-removed', tr(enabled, '暂无断点', 'No breakpoints'))
    probe(ui, 'next(require("dap.breakpoints").get()) == nil')
    ui.command('DvFocusSource')
    ui.send(F5)
    lua(ui, 'assert(vim.wait(10000, function() return not require("dap").session() and DvExitCode == 0 end));'
        'print("DV_EXIT_" .. "OK")')
    capture(ui, 'exit-verified', '\nTest 1', 'DV_EXIT_OK', timeout=12)


CASES = {'panel': panel, 'interaction': interaction, 'diagnostics': diagnostics, 'help': help_topics,
         'lifecycle': lifecycle, 'codelldb': codelldb}


def run_case(case, enabled, *, variant=None):
    source = Path(os.environ[DEPS[-1]])
    contents = Path(os.environ.get('NVIM_ZH_DAP_VIEW_MAIN', HERE / 'main.cpp')).read_text(encoding='utf-8')
    previous = dict(os.environ)
    with tempfile.TemporaryDirectory(prefix='nvim-zh-dap-view-tui-') as directory:
        directory = Path(directory)
        try:
            if case in ('panel', 'interaction', 'diagnostics'):
                os.environ['NVIM_ZH_DAP_VIEW_FIXTURE'] = str(HERE / 'fixture.lua')
            if variant == 'mismatch':
                shutil.copytree(source, directory / 'modified')
                modified = directory / 'modified/lua/dap-view/options/winbar/init.lua'
                with modified.open('a', encoding='utf-8') as stream:
                    stream.write('\n-- hash mismatch fixture\n')
                os.environ[DEPS[-1]] = str(directory / 'modified')
            extra = SETUP + (real_setup() if case == 'codelldb' else '\nDvSetup()\n')
            init = init_for(ID, enabled, extra, DEPS, verify=variant != 'missing')
            files = {'main.cpp': contents, 'virtual.c': 'int main(void) {\n    int counter = 7;\n    return counter;\n}\n'}
            with Terminal(directory, init, rows=46, cols=148, files=files) as ui:
                ui.evidence_name = f'{case}-{str(enabled).lower()}' + (f'-{variant}' if variant else '')
                ui.expect('NVIM_ZH_TUI_READY')
                if variant:
                    unverified(ui, enabled, variant == 'mismatch')
                else:
                    CASES[case](ui, enabled)
                return ui.screen.rows, ui.screen.cols
        finally:
            os.environ.clear()
            os.environ.update(previous)


if __name__ == '__main__':
    case = sys.argv[1]
    for enabled in (False, True):
        rows, cols = run_case(case, enabled)
        if case == 'lifecycle':
            for variant in ('missing', 'mismatch'):
                run_case(case, enabled, variant=variant)
        print(f'TUI=PASS adapter={ID} case={case} enabled={str(enabled).lower()} '
              f'term=xterm-256color rows={rows} cols={cols}', flush=True)
