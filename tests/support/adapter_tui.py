"""Drive a real Neovim terminal UI through a PTY and decode the visible screen."""
from __future__ import annotations

import ctypes as c
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT'])


class Screen:
    def __init__(self, temp, rows, cols):
        lib = temp / 'terminal_screen.so'
        subprocess.run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', '-o', str(lib),
                        str(ROOT / 'tests/support/terminal_screen.c'), '-lvterm'],
                       check=True, capture_output=True, timeout=15)
        self.lib = c.CDLL(str(lib))
        signatures = {
            'adapter_screen_new': ([c.c_int, c.c_int], c.c_void_p),
            'adapter_screen_cursor': ([c.c_void_p, c.POINTER(c.c_int)], None),
            'adapter_screen_read': ([c.c_void_p, c.POINTER(c.c_uint32)], None),
            'vterm_input_write': ([c.c_void_p, c.c_char_p, c.c_size_t], c.c_size_t),
            'vterm_output_read': ([c.c_void_p, c.c_char_p, c.c_size_t], c.c_size_t),
            'vterm_set_size': ([c.c_void_p, c.c_int, c.c_int], None),
            'vterm_free': ([c.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = args, result
        self.handle = self.lib.adapter_screen_new(rows, cols)
        if not self.handle:
            raise RuntimeError('libvterm allocation failed')
        self.rows, self.cols = rows, cols

    def close(self):
        self.lib.vterm_free(self.handle)

    def feed(self, data):
        if self.lib.vterm_input_write(self.handle, data, len(data)) != len(data):
            raise RuntimeError('libvterm did not consume the terminal stream')
        reply = c.create_string_buffer(4096)
        size = self.lib.vterm_output_read(self.handle, reply, len(reply))
        return reply.raw[:size]

    def cells(self):
        cells = (c.c_uint32 * (self.rows * self.cols * 8))()
        self.lib.adapter_screen_read(self.handle, cells)
        return cells

    def text(self):
        cells = self.cells()
        lines = []
        for row in range(self.rows):
            line = []
            for col in range(self.cols):
                start = (row * self.cols + col) * 8
                first = cells[start]
                if first == 0:
                    line.append(' ')
                elif first <= 0x10ffff:
                    line.extend(chr(value) for value in cells[start:start + 6] if value)
            lines.append(''.join(line).rstrip())
        return '\n'.join(lines)

    def widths(self, label):
        cells = self.cells()
        for row in range(self.rows):
            for col in range(self.cols):
                column, widths = col, []
                for char in label:
                    offset = (row * self.cols + column) * 8
                    if column >= self.cols or cells[offset] != ord(char):
                        break
                    width = cells[offset + 6]
                    widths.append(width)
                    column += width
                if len(widths) == len(label):
                    return widths
        raise AssertionError(f'label not found on screen: {label!r}')

    def cursor(self):
        position = (c.c_int * 2)()
        self.lib.adapter_screen_cursor(self.handle, position)
        return tuple(position)

    def resize(self, rows, cols):
        self.lib.vterm_set_size(self.handle, rows, cols)
        self.rows, self.cols = rows, cols


class Terminal:
    def __init__(self, temp, init, *, rows=32, cols=110, files=None):
        self.temp = temp
        self.cwd = temp / 'work'
        self.cwd.mkdir()
        for name, content in (files or {}).items():
            (self.cwd / name).write_text(content, encoding='utf-8')
        self.screen = Screen(temp, rows, cols)
        conf = temp / 'init.lua'
        conf.write_text(init, encoding='utf-8')
        self.raw = bytearray()
        self.exited = False
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(self.cwd)
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
                env = dict(os.environ, TERM='xterm-256color', LANG='C.UTF-8', LC_ALL='C.UTF-8')
                binary = env.get('NVIM_BIN', 'nvim')
                os.execvpe(binary, [binary, '-u', str(conf), '-i', 'NONE', '-n'], env)
            finally:
                os._exit(127)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, *_):
        try:
            if not self.exited:
                if exc_type is None:
                    self.send(b'\x1b\x1b:qa!\r')
                    deadline = time.monotonic() + 2
                    while not self.exited and time.monotonic() < deadline:
                        self.pump(.05)
                if not self.exited:
                    os.kill(self.pid, signal.SIGKILL)
                    os.waitpid(self.pid, 0)
        finally:
            os.close(self.fd)
            self.screen.close()

    def pump(self, wait):
        if select.select([self.fd], [], [], wait)[0]:
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b''
            if data:
                self.raw.extend(data)
                reply = self.screen.feed(data)
                if reply:
                    self.send(reply)
        self.exited, _ = os.waitpid(self.pid, os.WNOHANG)

    def send(self, keys):
        if isinstance(keys, str):
            keys = keys.encode()
        while keys:
            keys = keys[os.write(self.fd, keys):]

    def command(self, command):
        self.send(':' + command + '\r')

    def resize(self, rows, cols):
        self.screen.resize(rows, cols)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def expect(self, *needles, reject=(), timeout=7):
        deadline = time.monotonic() + timeout
        frame = ''
        while time.monotonic() < deadline and not self.exited:
            self.pump(.05)
            frame = self.screen.text()
            if all(needle in frame for needle in needles) and not any(needle in frame for needle in reject):
                return frame
        raise AssertionError(f'Expected {needles!r}\n{frame}\n'
                             f'cursor={self.screen.cursor()}\n'
                             f'terminal tail={bytes(self.raw[-3500:])!r}')


def lua_literal(value):
    import json
    return json.dumps(value, ensure_ascii=False)


def assert_lua(ui, expression, marker, *, timeout=7):
    # The marker must appear only after the Ex command executes.
    midpoint = len(marker) // 2
    ui.command(f"lua assert({expression}); print('{marker[:midpoint]}' .. '{marker[midpoint:]}')")
    ui.expect(marker, timeout=timeout)


def init_for(id, enabled, extra, dependencies, *, verify=False):
    imports = '\n'.join(f'vim.opt.rtp:prepend(assert(vim.env.{name}))' for name in dependencies)
    register = (f"zh.register_adapter_source({lua_literal(id)}, assert(vim.env.{dependencies[-1]}))"
                if verify else '')
    return f"""
vim.opt.loadplugins = false
vim.opt.rtp:prepend(vim.env.NVIM_ZH_ROOT)
{imports}
vim.o.shortmess = 'I'
vim.o.swapfile = false
vim.o.laststatus = 2
require('vim.lsp')
local zh = require('nvim-zh')
{register}
zh.setup({{ modules = {{ core = {{ enabled = false }}, plugins = {{ auto = {str(enabled).lower()} }} }} }})
{extra}
vim.api.nvim_create_autocmd('VimEnter', {{ once = true, callback = function()
  vim.api.nvim_echo({{{{ 'NVIM_ZH_TUI_READY' }}}}, false, {{}})
end }})
"""


def run(id, cases, *, dependencies, setup, verify=False, files=None):
    case = sys.argv[1]
    for enabled in (False, True):
        with tempfile.TemporaryDirectory(prefix=f'nvim-zh-{id}-tui-') as directory:
            init = init_for(id, enabled, setup, dependencies, verify=verify)
            with Terminal(Path(directory), init, files=files) as ui:
                ui.expect('NVIM_ZH_TUI_READY')
                cases[case](ui, enabled)
                print(f'TUI=PASS adapter={id} case={case} enabled={str(enabled).lower()} '
                      f'term=xterm-256color rows={ui.screen.rows} cols={ui.screen.cols}')


def git(repository, *args):
    return subprocess.check_output(['git', '-C', str(repository), *args], text=True, timeout=20,
                                   env=dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null',
                                            GIT_CONFIG_SYSTEM='/dev/null')).strip()


def commit(repository, message):
    git(repository, 'add', '.')
    git(repository, '-c', 'user.name=Adapter TUI', '-c', 'user.email=tui@example.invalid',
        'commit', '-m', message)
    return git(repository, 'rev-parse', 'HEAD')
