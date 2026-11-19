from adapter_tui import lua_literal, run


def find_files(ui, enabled):
    title, results = ('查找文件', '结果') if enabled else ('Find Files', 'Results')
    ui.command('Telescope find_files')
    ui.expect(title, results, 'fixture-one.txt')
    ui.resize(24, 86)
    ui.expect(title, results)
    if enabled:
        assert ui.screen.widths(title) == [2, 2, 2, 2]
    ui.send('fixture-two')
    ui.expect('fixture-two.txt', reject=('fixture-one.txt',))
    ui.send(b'\r')
    ui.expect('TELESCOPE_FILE_OPENED')
    ui.command('Telescope find_files')
    ui.expect(title, results)
    ui.send(b'\x1b\x1b')
    ui.expect('TELESCOPE_FILE_OPENED', reject=(title,))
    ui.command('lua require("telescope.builtin").find_files({prompt_title = "Find Files"})')
    ui.expect('Find Files', results, 'fixture-one.txt')
    ui.send(b'\x1b\x1b')


def notification(ui, enabled):
    ui.command('Telescope quickfix')
    ui.expect('没有快速修复项' if enabled else 'No quickfix items')
    ui.command('lua vim.notify("[telescope.builtin.quickfix]: No quickfix items", nil, {title="telescope.nvim"})')
    ui.expect('No quickfix items', reject=('没有快速修复项',))


def notification_matrix(ui, enabled):
    # Each call uses the real utils.notify path with a real funname; the
    # function name is dynamic data and stays verbatim, the body is projected.
    # Long notifications wrap and get truncated by the message area, so each
    # case asserts a short distinctive slice plus the unchanged prefix/funname.
    calls = [
        ("filter_symbols", "Either opts.symbols or opts.ignore_symbols, can't process opposing options at the same time!",
         "只能取其一", "Either opts.symbols"),
        ("git_branches", "Switched to a new branch: feature-x", "已切换到新分支：feature-x",
         "Switched to a new branch: feature-x"),
        ("lsp_workspace_symbols", "server does not support workspace/symbol", "服务器不支持 workspace/symbol",
         "server does not support workspace/symbol"),
        ("git_branches", "Reset to: 'main'", "已重置到：'main'", "Reset to: 'main'"),
        ("git_branches", "action canceled", "操作已取消", "action canceled"),
    ]
    for fn, body, zh, en in calls:
        ui.command('lua NotifyVia("%s", %s)' % (fn, lua_literal(body)))
        expected = zh if enabled else en
        frame = ui.expect(expected, '[telescope.%s]' % fn)
        if enabled:
            assert en not in frame, frame
        else:
            assert zh not in frame, frame
        ui.send(b'\r')
        ui.pump(0.2)


def error_branch(ui, enabled):
    # Real plugin validation branch: pickers.find reports an invalid
    # initial_mode through utils.notify. The picker still opens, so close it
    # first and read the notification from the message history.
    ui.command('lua pcall(function() require("telescope.builtin").find_files({ initial_mode = "bogus" }) end)')
    ui.expect('结果' if enabled else 'Results')
    ui.send(b'\x1b\x1b')
    ui.pump(0.4)
    ui.command('messages')
    expected = '`initial_mode`' if enabled else '`initial_mode` should be one of'
    frame = ui.expect(expected, 'bogus')
    if enabled:
        assert '应为' in frame, frame
    else:
        assert 'should be one of' in frame.replace('\n', ' '), frame
    ui.command('q')
    ui.pump(0.3)


def help_topic(ui, enabled):
    ui.command('lua AdapterTestHelpTags()')
    ui.command('help telescope.defaults.sorting_strategy')
    ui.expect('设置搜索结果的显示顺序' if enabled else 'Determines the direction')
    ui.command('help telescope.defaults.selection_strategy')
    ui.expect('selection_strategy:')


def refine(ui, enabled):
    # Real path: live_grep's <C-space> mapping calls actions.to_fuzzy_refine,
    # which decides its English prefix from the picker's INTERNAL prompt_title
    # ("Live Grep") and then hands "<prefix> (<line>)" to the public
    # generate.refine, which only forwards it to border:change_title. Only that
    # display copy is projected; the internal behaviour value stays English and
    # the typed query stays byte-identical.
    ui.command('Telescope live_grep')
    ui.expect('实时 Grep' if enabled else 'Live Grep', timeout=12)
    # live_grep lists nothing until a query is typed; TELESCOPE is present in
    # the fixture files, so the match row proves the finder is live.
    ui.send('TELESCOPE')
    ui.expect('fixture-one.txt')
    ui.send(b'\x00')  # <C-space> sends NUL through a PTY; real mapping
    expected = '查找单词 (TELESCOPE)' if enabled else 'Find Word (TELESCOPE)'
    frame = ui.expect(expected)
    if enabled:
        assert 'Find Word (TELESCOPE)' not in frame, frame
    else:
        assert '查找单词' not in frame, frame
    # The typed query survives byte-identically.
    ui.expect('TELESCOPE')
    ui.send(b'\x1b\x1b')
    ui.pump(0.3)


def which_key(ui, enabled):
    # The float is a self-made plenary popup whose border title is the only
    # translated part. Its keymap rows are plugin data and must stay verbatim.
    ui.command('Telescope find_files')
    ui.expect('查找文件' if enabled else 'Find Files', 'fixture-one.txt')
    # "?" is bound in normal mode only (mappings.lua:228); leave insert mode first.
    ui.send(b'\x1b')
    ui.pump(0.4)
    ui.send(b'?')
    title = '普通模式按键映射' if enabled else 'Normal Mode Keymaps'
    frame = ui.expect(title)
    if enabled:
        assert 'Normal Mode Keymaps' not in frame, frame
    else:
        assert '普通模式按键映射' not in frame, frame
    # The float renders its keymap rows in the same border; the popup is closed with
    # <Esc> and the picker underneath keeps its own (projected) title.
    ui.expect('查找文件' if enabled else 'Find Files')
    ui.send(b'\x1b')
    ui.pump(0.5)
    ui.send(b'\x1b\x1b')
    ui.pump(0.4)



def _open_branches(ui, enabled):
    ui.command('lua FixtureGitRepo()')
    ui.expect('GIT_REPO_READY')
    ui.command('lua FixtureGitPicker()')
    ui.expect('Git 分支' if enabled else 'Git Branches', 'zz-keep-branch')


def _assert(ui, enabled, frame, translated, english):
    """Assert only the projected copy of one prompt is on screen."""
    if enabled:
        assert translated in frame, frame
        assert english not in frame, frame
    else:
        assert english in frame, frame
        assert translated not in frame, frame


# Each git prompt runs in its own session: declining closes the picker, and a
# second vim.fn.input in the same session would race the closed prompt window.
def input_prompts(ui, enabled):
    # git_delete_branch -> ask_to_confirm(prompt, "y"): the two-argument form.
    # The trailing "y" on the prompt line is the default the helper passed in, so
    # asserting it proves the argument list still crosses the projection intact.
    _open_branches(ui, enabled)
    ui.send(b'\x04')
    frame = ui.expect('确实要删除选中的分支吗？[Y/n] y' if enabled
                      else 'Do you really want to delete the selected branches? [Y/n] y')
    _assert(ui, enabled, frame, '确实要删除选中的分支吗？[Y/n]',
            'Do you really want to delete the selected branches? [Y/n]')


def input_prompts_merge(ui, enabled):
    # git_merge_branch -> make_git_branch_action -> ask_to_confirm(prompt, "y"):
    # the one-argument form, whose branch-name interpolation and default must both
    # survive.
    _open_branches(ui, enabled)
    ui.send(b'\x19')
    frame = ui.expect('确实要合并分支 zz-keep-branch 吗？[Y/n] y' if enabled
                      else 'Do you really want to merge branch zz-keep-branch? [Y/n] y')
    _assert(ui, enabled, frame, '确实要合并分支 zz-keep-branch 吗？[Y/n]',
            'Do you really want to merge branch zz-keep-branch? [Y/n]')


def input_prompts_rebase(ui, enabled):
    # git_rebase_branch uses the same helper with a different verb; the verb is the
    # only part that differs in the catalog entry.
    _open_branches(ui, enabled)
    ui.send(b'\x12')
    frame = ui.expect('确实要变基到分支 zz-keep-branch 吗？[Y/n] y' if enabled
                      else 'Do you really want to rebase branch zz-keep-branch? [Y/n] y')
    _assert(ui, enabled, frame, '确实要变基到分支 zz-keep-branch 吗？[Y/n]',
            'Do you really want to rebase branch zz-keep-branch? [Y/n]')


def input_prompts_create(ui, enabled):
    # git_create_branch gets the new branch name from a different prompt (the
    # picker line) and interpolates it into the [y/n] question. Its default is
    # empty, so the line ends right after the colon.
    _open_branches(ui, enabled)
    # The prompt is in insert mode when the picker mounts; send the branch name,
    # then leave insert mode so <C-a> is read as the real normal-mode mapping.
    ui.send(b'zz-new-branch')
    ui.pump(0.5)
    ui.send(b'\x1b')
    ui.pump(0.3)
    ui.send(b'\x01')
    frame = ui.expect("创建新分支 'zz-new-branch'？[y/n]：" if enabled
                      else "Create new branch 'zz-new-branch'? [y/n]:")
    _assert(ui, enabled, frame, "创建新分支 'zz-new-branch'？[y/n]：",
            "Create new branch 'zz-new-branch'? [y/n]:")


def action_output(ui, enabled):
    # telescope's internal builtins register their select callback from inside
    # Picker:find, defined in builtin/__internal.lua. That is the frame the print
    # projection matches on, so the check is: run the real mapping, let the callback
    # print, and read the message history afterwards.
    #
    # print has no notify route, so the line is only observable once the picker is
    # gone. <Esc><Esc> closes it and returns to normal mode, where :messages works.
    ui.command('Telescope planets')
    ui.expect('行星' if enabled else 'Planets', timeout=10)
    ui.expect('earth')
    ui.pump(0.6)
    ui.send(b'\r')
    ui.pump(1.0)
    ui.send(b'\x1b')
    ui.pump(0.4)
    ui.send(b'\x1b')
    ui.pump(0.6)
    ui.command('messages')
    frame = ui.expect('享受天文吧！你查看了：' if enabled else 'Enjoy astronomy! You viewed:', 'earth')
    _assert(ui, enabled, frame, '享受天文吧！你查看了：', 'Enjoy astronomy! You viewed:')
    # The selected planet is user data and stays byte-identical.
    assert ' earth' in frame, frame


def action_output_filetypes(ui, enabled):
    # filetypes' callback is registered with replace(); only a nil selection reaches
    # the hand-written "[telescope] ..." print. Pressing <CR> with no entry under
    # the cursor is exactly that branch, and the callback closes the picker itself.
    ui.command('Telescope filetypes')
    ui.expect('文件类型' if enabled else 'Filetypes', timeout=10)
    ui.command('lua FixturePressFiletypes()')
    ui.pump(1.2)
    ui.send(b'\x1b')
    ui.pump(0.5)
    ui.command('messages')
    frame = ui.expect('[telescope] 当前没有选中项' if enabled
                      else '[telescope] Nothing currently selected')
    _assert(ui, enabled, frame, '[telescope] 当前没有选中项',
            '[telescope] Nothing currently selected')



def health(ui, enabled):
    ui.command('checkhealth telescope')
    ui.expect('检查必需的插件' if enabled else 'Checking for required plugins', timeout=10)
    ui.expect('检查外部依赖' if enabled else 'Checking external dependencies')
    ui.command('lua CheckCombinedHealth()')
    ui.expect('检查必需的插件' if enabled else 'Checking for required plugins')
    ui.command('normal! G')
    ui.expect('未发现重复映射' if enabled else 'No duplicate mappings found')
    ui.expect('已安装的扩展' if enabled else 'Installed extensions')
    # Dynamic data stays verbatim: the binary name and its version string. The
    # name/colon separator belongs to the "%s: found %s" template, so the version
    # is the stable payload to assert.
    ui.expect('ripgrep')
    if enabled:
        assert 'Checking for required plugins' not in ui.screen.text()
    else:
        assert '检查必需的插件' not in ui.screen.text()
    # A second report in the same session must translate again: the leaf module is
    # re-required per report instead of being bound once.
    ui.command('checkhealth telescope')
    ui.expect('检查必需的插件' if enabled else 'Checking for required plugins', timeout=10)
    ui.expect('检查外部依赖' if enabled else 'Checking external dependencies')


run('telescope', {'find_files': find_files, 'notification': notification,
                 'notification_matrix': notification_matrix, 'help': help_topic,
                 'error_branch': error_branch, 'refine': refine, 'which_key': which_key,
                 'input_prompts': input_prompts,
                 'input_prompts_merge': input_prompts_merge,
                 'input_prompts_rebase': input_prompts_rebase,
                 'input_prompts_create': input_prompts_create,
                 'action_output': action_output,
                 'action_output_filetypes': action_output_filetypes,
                 'health': health},
    dependencies=('NVIM_ZH_TEST_PLENARY', 'NVIM_ZH_TEST_TELESCOPE'), verify=True,
    setup="""
vim.cmd('runtime plugin/telescope.lua')
require('telescope').setup({ defaults = { layout_strategy = 'horizontal' } })
function NotifyVia(fn, body)
  require('telescope.utils').notify(fn, { msg = body, level = 'WARN' })
end
function CheckCombinedHealth()
  local root = assert(vim.env.NVIM_ZH_TEST_WHICH_KEY)
  vim.opt.rtp:prepend(root)
  zh.register_adapter_source('which-key', root)
  require('which-key').setup()
  vim.cmd('checkhealth telescope which-key')
end
function AdapterTestHelpTags()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/doc', 'p')
  local source = vim.env.NVIM_ZH_TEST_TELESCOPE .. '/doc/telescope.txt'
  assert(vim.uv.fs_copyfile(source, root .. '/doc/telescope.txt'))
  vim.cmd.helptags(root .. '/doc')
  vim.opt.rtp:append(root)
  require('nvim-zh').refresh()
end
function FixtureGitRepo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local run = function(args)
    local out = vim.fn.system('git -C ' .. vim.fn.shellescape(root) .. ' ' .. args)
    assert(vim.v.shell_error == 0, args .. ': ' .. tostring(out))
  end
  run('init -b main')
  run('-c user.name=AdapterTUI -c user.email=tui@example.invalid commit --allow-empty -m one')
  run('branch zz-keep-branch')
  vim.cmd('cd ' .. vim.fn.fnamemodify(root, ':p'))
  vim.fn.writefile({ 'GIT_REPO_READY' }, root .. '/zz-ready.txt')
  vim.cmd('silent edit ' .. vim.fn.fnameescape(root .. '/zz-ready.txt'))
end
function FixtureGitPicker()
  local actions = require('telescope.actions')
  local finders = require('telescope.finders')
  local pickers = require('telescope.pickers')
  local conf = require('telescope.config').values
  local items = { { value = 'zz-keep-branch', ordinal = 'zz-keep-branch', display = 'zz-keep-branch' } }
  pickers.new({ cwd = vim.fn.getcwd() }, {
    prompt_title = 'Git Branches',
    finder = finders.new_table({ results = items, entry_maker = function(x) return x end }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, map)
      map({ 'i', 'n' }, '<C-d>', actions.git_delete_branch)
      map({ 'i', 'n' }, '<C-y>', actions.git_merge_branch)
      map({ 'i', 'n' }, '<C-r>', actions.git_rebase_branch)
      map({ 'i', 'n' }, '<C-a>', actions.git_create_branch)
      return true
    end,
  }):find()
end
function FixturePressFiletypes()
  -- Press <CR> with no entry under the cursor: that is the only branch that
  -- reaches the plugin's hand-written "[telescope] ..." print. The prompt buffer
  -- is found from the picker registry, so this works whether or not the prompt is
  -- the current window.
  local actions = require('telescope.actions')
  local state = require('telescope.actions.state')
  local prompt_bufnr
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buftype == 'prompt' and state.get_status(buf) then prompt_bufnr = buf end
  end
  assert(prompt_bufnr, 'no picker prompt found')
  local original = state.get_selected_entry
  state.get_selected_entry = function() return nil end
  local ok, err = pcall(actions.select_default, prompt_bufnr)
  state.get_selected_entry = original
  assert(ok, tostring(err))
end
""", files={'fixture-one.txt': 'FIRST_TELESCOPE_FILE\n', 'fixture-two.txt': 'TELESCOPE_FILE_OPENED\n'})
# Notification coverage added by the full audit: every fixed utils.notify
# message that the pinned source can emit goes through the same
# "[telescope.<fn>]: <msg>" route. The generic picker name is dynamic (it is
# the calling function), so only the message body is asserted verbatim.
