from adapter_tui import run


def tree(ui, enabled):
    ui.command('NvimTreeOpen')
    ui.expect('tree-fixture.txt')
    ui.send('g?')
    ui.expect('打开：垂直分屏' if enabled else 'Open: Vertical Split')
    ui.send('q')
    ui.command('NvimTreeClose')
    ui.command('NvimTreeOpen')
    ui.expect('tree-fixture.txt')
    ui.send('/tree-fixture.txt\r')
    ui.send(b'\r')
    ui.expect('TREE_FIXTURE')


def notification(ui, enabled):
    ui.command('lua require("nvim-tree.notify").info("Clipboard has been emptied.")')
    ui.expect('剪贴板已清空' if enabled else 'Clipboard has been emptied.')


def notification_matrix(ui, enabled):
    # Fixed notify texts the audit found unregistered. Each call goes through a
    # helper defined in init.lua that lives outside the plugin tree, so the
    # notification source matcher (which requires a lua/nvim-tree/notify.lua
    # frame) must still see the real dispatch: the helper calls
    # require("nvim-tree.config") first, then the plugin's own notify module.
    # Dynamic payloads (paths, OS errors, options) stay verbatim.
    calls = [
        ('FixtureNotify("warn", "file already exists")', '文件已存在', 'file already exists'),
        ('FixtureNotify("error", "nvim-tree setup not called")', '尚未调用 nvim-tree setup', 'nvim-tree setup not called'),
        ('FixtureNotify("warn", "Unknown option: renderer.foo")', '未知选项：renderer.foo', 'Unknown option: renderer.foo'),
        ('FixtureNotify("warn", "Copied a.txt to system clipboard!")', '已将', 'Copied'),
    ]
    for command, zh, en in calls:
        ui.command('lua ' + command)
        ui.expect(zh if enabled else en)


def help_topic(ui, enabled):
    ui.command('lua AdapterTestHelpTags()')
    ui.command('help nvim-tree-mappings')
    ui.expect('映射通过' if enabled else 'Mappings are set via')
    # Tags stay resolvable and the default-mapping list remains reachable.
    ui.expect('nvim-tree-mappings-default')


def prompts(ui, enabled):
    # Item 1: lib.prompt display arguments. select_prompts defaults to false
    # (config.lua:47), so the default path is vim.ui.input, which renders the
    # prompt on the command line. The node name and the y/N marker are data and
    # stay byte-identical; only the surrounding copy is projected.
    ui.command('NvimTreeOpen')
    ui.expect('prompt-fixture.txt')
    ui.command('lua FocusTreePromptFixture()')
    ui.send('d')
    if enabled:
        ui.expect('删除 prompt-fixture.txt？y/N:', reject=('Remove prompt-fixture.txt?',))
    else:
        ui.expect('Remove prompt-fixture.txt? y/N:', reject=('删除',))
    ui.send('n\r')
    ui.expect('prompt-fixture.txt')

    # Bookmarked bulk delete goes through the same lib.prompt dispatcher with
    # its own kind and a fixed prompt.
    ui.command('lua FocusTreePromptFixture()')
    ui.send('m')
    ui.send('bd')
    if enabled:
        ui.expect('删除书签节点？y/N:', reject=('Remove bookmarked ?',))
    else:
        ui.expect('Remove bookmarked ? y/N:', reject=('删除书签节点',))
    ui.send('n\r')

    # The select branch renders items_long as labels. The short codes ("", "y")
    # are protocol values, so answering "y" must still delete the node after the
    # labels are projected -- that is what proves the callback value is intact.
    ui.command('lua SetSelectPrompts(true)')
    ui.command('lua FocusTreePromptFixture()')
    ui.send('d')
    if enabled:
        ui.expect('是', '否', reject=('Yes', 'No'))
    else:
        ui.expect('Yes', 'No', reject=('是', '否'))
    ui.send('y\r')
    ui.command('lua SetSelectPrompts(false)')
    ui.command('lua RestorePromptFixture()')
    ui.expect('prompt-fixture.txt')


def help_buffer(ui, enabled):
    # Item 3: the private help buffer opened by `g?`. Its two header lines come
    # from the local compute() in help.lua:89-176 and the window is sized from
    # that computed width, so a projected header must keep them consistent.
    ui.command('NvimTreeOpen')
    ui.expect('tree-fixture.txt')
    ui.send('g?')
    if enabled:
        ui.expect('nvim-tree 映射', '退出：q', '按描述排序：s',
                  reject=('nvim-tree mappings', 'exit: q', 'sort by description: s'))
    else:
        ui.expect('nvim-tree mappings', 'exit: q', 'sort by description: s',
                  reject=('nvim-tree 映射', '退出：q'))
    # The `s` key still toggles the sort method, and the second header line
    # follows it.
    ui.send('s')
    ui.expect('按按键排序：s' if enabled else 'sort by keymap: s')
    if enabled:
        ui.command('lua CheckHelpAlignment()')
    # Narrow window: the right-hand column must stay visible and aligned.
    ui.resize(24, 80)
    ui.expect('按按键排序：s' if enabled else 'sort by keymap: s')
    ui.send('q')
    # The help-local keymaps still close the buffer.
    ui.send('g?')
    ui.expect('nvim-tree 映射' if enabled else 'nvim-tree mappings')
    ui.send('q')
    ui.expect('tree-fixture.txt', reject=('nvim-tree 映射', 'nvim-tree mappings'))


def file_info(ui, enabled):
    # Item 5: the <C-k> file info popup. Labels are projected; the path, the
    # dates, the size value and the popup geometry around them are unchanged.
    ui.command('NvimTreeOpen')
    ui.expect('info-fixture.txt')
    ui.command('lua FocusTreeInfoFixture()')
    ui.send('\x0b')  # <C-k>
    if enabled:
        ui.expect('完整路径：', '大小：', reject=('fullpath:', 'size:'))
    else:
        ui.expect('fullpath:', 'size:', reject=('完整路径：', '大小：'))
    # The value column keeps the real file name and the real byte size.
    ui.expect('info-fixture.txt', '13 B')
    # CursorMoved still closes the popup.
    ui.send('j')
    ui.expect('info-fixture.txt', reject=('完整路径：', 'fullpath:'))
    # The popup must fit a narrow terminal without truncating the path label.
    ui.resize(24, 80)
    ui.command('lua FocusTreeInfoFixture()')
    ui.send('\x0b')
    ui.expect('完整路径：' if enabled else 'fullpath:')
    ui.send('j')


def window_picker(ui, enabled):
    # Item 4: print("Pick window: ") is emitted only while cmdheight != 0 and
    # at least two selectable windows exist (open-file.lua:137-140).
    ui.command('NvimTreeOpen')
    ui.expect('tree-fixture.txt')
    ui.command('lua ArmWindowPicker()')
    ui.command('lua FocusTreePromptFixture()')
    # The default vertical-split mapping is <C-v>; bare `v` is not mapped by
    # nvim-tree's default on_attach (keymap.lua:65), so it must not be used here.
    ui.send(b'\x16')
    if enabled:
        ui.expect('选择 Window：', reject=('Pick window:',))
    else:
        ui.expect('Pick window:', reject=('选择 Window：',))
    # An unmapped identifier cancels the picker and leaves the tree intact.
    ui.send('z')
    ui.expect('tree-fixture.txt')


def renderer_hidden(ui, enabled):
    # Item 6: the hidden-count virtual line. It only exists with
    # renderer.hidden_display = "simple" (the default is "none"), and its
    # skeleton is projected while the number stays.
    ui.command('lua EnableHiddenDisplay("simple")')
    ui.command('NvimTreeOpen')
    ui.expect('hidden-folder')
    ui.command('lua FocusTreeFolder()')
    ui.send('\r')
    if enabled:
        ui.expect('隐藏 2 个', reject=('(2 hidden)',))
    else:
        ui.expect('(2 hidden)', reject=('隐藏 2 个',))
    ui.command('lua EnableHiddenDisplay("all")')
    if enabled:
        ui.expect('隐藏 2：点文件：2', reject=('dotfile: 2',))
    else:
        ui.expect('(2 total dotfile: 2)', reject=('点文件：2',))


run('nvim-tree', {'tree': tree, 'notification': notification, 'notification_matrix': notification_matrix,
                  'help': help_topic, 'prompts': prompts, 'help_buffer': help_buffer,
                  'file_info': file_info, 'window_picker': window_picker,
                  'renderer_hidden': renderer_hidden},
    dependencies=('NVIM_ZH_TEST_NVIM_TREE',), verify=True,
    setup="""
function FixtureNotify(level, msg)
  -- Route through the real plugin dispatch so the notification keeps its
  -- [NvimTree] prefix/title and the adapter's source matcher applies.
  require('nvim-tree.notify')[level](msg)
end
require('nvim-tree').setup({ git = { enable = false }, filesystem_watchers = { enable = false } })
vim.cmd('runtime plugin/nvim-tree.lua')
function AdapterTestHelpTags()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/doc', 'p')
  local source = vim.env.NVIM_ZH_TEST_NVIM_TREE .. '/doc/nvim-tree-lua.txt'
  assert(vim.uv.fs_copyfile(source, root .. '/doc/nvim-tree-lua.txt'))
  vim.cmd.helptags(root .. '/doc')
  vim.opt.rtp:append(root)
  require('nvim-zh').refresh()
end

-- A folder with two dotfiles so the hidden-count virtual line has a real count.
function MakeHiddenFolder()
  local cwd = vim.fn.getcwd()
  vim.fn.mkdir(cwd .. '/hidden-folder', 'p')
  vim.fn.writefile({ 'H' }, cwd .. '/hidden-folder/.hidden1')
  vim.fn.writefile({ 'H' }, cwd .. '/hidden-folder/.hidden2')
end
MakeHiddenFolder()

-- Focus a node by name so each case is independent of tree ordering and of
-- whatever a previous case left selected.
function FocusNodeByName(name)
  local api = require('nvim-tree.api')
  local view = require('nvim-tree.view')
  if not view.is_visible() then api.tree.open() end
  local bufnr = view.get_bufnr()
  for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(name, 1, true) then
      vim.api.nvim_win_set_cursor(view.get_winnr(), { index, 0 })
      return true
    end
  end
  return false
end

function FocusTreePromptFixture() assert(FocusNodeByName('prompt-fixture.txt')) end
function FocusTreeInfoFixture() assert(FocusNodeByName('info-fixture.txt')) end
function FocusTreeFolder() assert(FocusNodeByName('hidden-folder')) end

function CheckHelpAlignment()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 2, false)
  assert(vim.fn.strdisplaywidth(lines[1]) == vim.fn.strdisplaywidth(lines[2]))
  local mapping = vim.fn.maparg('s', 'n', false, true)
  assert(mapping.desc == 'nvim-tree: 切换排序方式')
end

function SetSelectPrompts(value)
  require('nvim-tree.config').g.select_prompts = value
end

-- The select branch may consume the fixture when the callback value is intact,
-- so put it back for the next run.
function RestorePromptFixture()
  vim.fn.writefile({ 'PROMPT_FIXTURE' }, vim.fn.getcwd() .. '/prompt-fixture.txt')
  require('nvim-tree.api').tree.reload()
end

function EnableHiddenDisplay(mode)
  require('nvim-tree.config').g.renderer.hidden_display = mode
  -- `filters.dotfiles` defaults to false, i.e. dotfiles are SHOWN and therefore
  -- nothing is hidden. Turn the filter on so the two fixture dotfiles actually
  -- count as hidden and the virtual line has a non-zero total.
  require('nvim-tree.config').g.filters.dotfiles = true
  require('nvim-tree.api').tree.reload()
end

-- Two extra selectable windows so the default window picker engages, and a
-- non-zero cmdheight because the print is skipped at cmdheight 0.
function ArmWindowPicker()
  vim.cmd('wincmd p')
  vim.cmd('split')
  vim.cmd('split')
  vim.o.cmdheight = 1
  require('nvim-tree.api').tree.open({ focus = true })
end

""", files={'tree-fixture.txt': 'TREE_FIXTURE\n',
            'prompt-fixture.txt': 'PROMPT_FIXTURE\n',
            'info-fixture.txt': 'INFO_FIXTURE\n'})
