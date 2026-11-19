import os
import sys
import tempfile
import time

from adapter_tui import run

SETUP = """
vim.cmd('runtime plugin/which-key.lua')
require('which-key').setup({ delay = 0, icons = { mappings = false } })
"""


def open_popup(ui, keys, content):
    """Open a popup and wait until its body is on screen (popup owns input)."""
    ui.command('WhichKey ' + keys)
    ui.expect(content)


def close_popup(ui, content):
    """Close the popup and wait for it to leave the screen (deferred hide)."""
    ui.send(b'\x1b')
    deadline = time.monotonic() + 5
    frame = ''
    while time.monotonic() < deadline:
        ui.pump(0.05)
        frame = ui.screen.text()
        if content not in frame:
            return
    raise AssertionError(f'popup did not close:\n{frame}')


def mappings(ui, enabled):
    toggle = '切换注释' if enabled else 'Toggle comment'
    open_popup(ui, 'g', toggle)
    close_popup(ui, toggle)
    open_popup(ui, 'g', toggle)
    close_popup(ui, toggle)


def notification(ui, enabled):
    ui.command('WhichKey unsupported_mode')
    ui.expect('找不到模式' if enabled else 'No mappings found for mode')


def footer(ui, enabled):
    toggle = '切换注释' if enabled else 'Toggle comment'
    close, back = ('关闭', '返回') if enabled else ('close', 'back')
    # Root popup shows only the close hint.
    open_popup(ui, 'g', toggle)
    ui.expect(close)
    close_popup(ui, toggle)
    # A nested group adds the back hint.
    split = '垂直拆分 Window' if enabled else 'Split window vertically'
    open_popup(ui, '<c-w>', split)
    frame = ui.expect(back, close)
    assert ('返回' in frame) == enabled
    close_popup(ui, split)
    # The scroll hint appears only when the content is taller than the window.
    ui.resize(12, 80)
    ui.command('WhichKey g')
    ui.expect('滚动' if enabled else 'scroll', close)
    ui.send(b'\x1b')
    ui.pump(0.4)
    ui.resize(32, 110)


def health(ui, enabled):
    ui.command('checkhealth which-key')
    ui.expect('检查你的配置' if enabled else 'Checking your config', timeout=10)
    ui.expect('检查重叠的键映射' if enabled else 'checking for overlapping keymaps')
    ui.expect('未发现重复映射' if enabled else 'No duplicate mappings found')
    # Dynamic values (provider names, modes, keys) stay verbatim.
    ui.expect('which-key:')
    ui.command('q')


def plugin_labels(ui, enabled):
    # File marks: the fixed "file: " prefix is plugin-owned, the path is data.
    # Different marks can share one edge, so accept either the prose label or
    # the file prefix, then assert which one this mode actually produced.
    ui.command('edit probe.txt')
    ui.command('normal! GmA')
    marker = '文件：' if enabled else 'file: '
    ui.command('WhichKey `')
    frame = ui.expect(marker, 'probe.txt')
    assert ('文件：' in frame) != ('file: ' in frame), frame
    ui.send(b'\x1b')
    time.sleep(0.5)
    # OSC 52 register notice is a fixed plugin string; register data is not.
    ui.command('lua vim.g.clipboard = { name = "OSC 52" }')
    ui.command('WhichKey "')
    ui.expect('检测到 OSC 52' if enabled else 'OSC 52 detected', 'probe.txt')
    ui.send(b'\x1b')
    time.sleep(0.4)


def help_topic(ui, enabled):
    ui.command('lua AdapterTestHelpTags()')
    ui.command('help which-key.nvim-which-key-usage')
    ui.expect('取消并关闭弹窗' if enabled else 'cancel and close the popup')
    # Keys, tags and example spacing stay intact.
    ui.expect('<c-d>', '<bs>')


run('which-key', {'mappings': mappings, 'notification': notification, 'footer': footer,
                  'health': health, 'plugin_labels': plugin_labels, 'help': help_topic},
    dependencies=('NVIM_ZH_TEST_WHICH_KEY',), verify=True,
    setup=SETUP + """
function AdapterTestHelpTags()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/doc', 'p')
  local source = vim.env.NVIM_ZH_TEST_WHICH_KEY .. '/doc/which-key.nvim.txt'
  assert(vim.uv.fs_copyfile(source, root .. '/doc/which-key.nvim.txt'))
  vim.cmd.helptags(root .. '/doc')
  vim.opt.rtp:append(root)
  require('nvim-zh').refresh()
end
""", files={'probe.txt': 'local counter = 1\nprint(counter)\n'})