"""Drive the same Clang/clangd/clang-tidy project with Chinese on and off."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re

from adapter_tui import Terminal, assert_lua, lua_literal
from pack_assets import assets

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
MAIN = """/// Parameters:
int sum(int x, int y) { return x + y; }
int sum(double x, double y) { return int(x + y); }
int main() {
  return sum(1, 2)
}
"""
NOTES = """int repeated = 1;
int repeated = 2;
"""
TIDY = """int wrap(int *p, int v) { return p == 0 ? v : *p; }
int pair(int left, int right) {
  if (left < 100) return 1;
  return right * 100;
}
"""
FILES = {'练习.cpp': MAIN, '说明.cpp': NOTES, '检查.cpp': TIDY,
         '补全.cpp': 'int sum(int x, int y);\nint sum(double x, double y);\nvoid test() { su; }\n',
         '项目.c': 'int value(void) { return 1; }\n',
         '碰撞.c': "#error expected ';' after return statement\n",
         '未知.c': 'int main(void) { return 0 }\n',
         '.clang-tidy': 'Checks: "-*,modernize-use-nullptr,bugprone-easily-swappable-parameters"\n',
         '.clangd': 'Diagnostics:\n  ClangTidy:\n    FastCheckFilter: None\n'}
COMPARED_METHODS = ('textDocument/hover', 'textDocument/signatureHelp', 'textDocument/completion',
                    'textDocument/codeAction', 'workspace/executeCommand', 'textDocument/diagnostic',
                    'workspace/diagnostic', 'completionItem/resolve')


def lua(ui, command):
    ui.command('lua ' + command)


def frame(ui, evidence, name, *needles, **kwargs):
    text = ui.expect(*needles, **kwargs)
    (evidence / (name + '.txt')).write_text(text + '\n')
    return text


def run(base, enabled):
    evidence = base
    report = base / 'wire.json'
    os.environ.update(NVIM_ZH_LANGUAGE='on' if enabled else 'off',
                      NVIM_ZH_TOOLCHAIN_RESULT=str(report), XDG_DATA_HOME=str(base / 'data'),
                      XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
                      XDG_CONFIG_HOME=str(base / 'config'))
    candidate = base / 'candidate'
    candidate.mkdir()
    os.environ['NVIM_ZH_TEST_TOOLCHAIN_ASSETS'] = str(candidate)
    for tool in ('clang', 'clangd', 'clang-tidy'):
        filename, content, _ = next(assets(ROOT, '1.0.0', 'https://example.invalid/nvim-zh', tool))
        (candidate / filename).write_bytes(content)
    work = base / 'work'
    unknown = base / 'clang'
    unknown.write_text('#!/bin/sh\nif [ "$1" = --version ]; then echo "clang version 99.1.0"; exit 0; fi\n'
                       'exec /usr/bin/clang "$@"\n')
    unknown.chmod(0o755)
    files = dict(FILES, **{'compile_commands.json': json.dumps([
        {'directory': str(work), 'arguments': ['clang++', '-std=c++20', '-c', name], 'file': name}
        for name in FILES if name.endswith('.cpp')
    ])})
    init = (ROOT / 'tests/workflows/clang_toolchain.lua').read_text()
    with Terminal(base, init, rows=36, cols=133, files=files) as ui:
        try:
            frame(ui, evidence, 'start', 'TOOLCHAIN_READY')
            ui.command('help nvim-zh-cpp')
            frame(ui, evidence, 'help', 'C/C++ 工作流' if enabled else 'C/C++ WORKFLOW')
            ui.command('close')
            ui.command('edit 练习.cpp')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang++\\ -fsyntax-only\\ -std=c++20\\ 练习.cpp')
            ui.command('silent make!')
            ui.command('copen')
            frame(ui, evidence, 'compile-failed', "return 语句后缺少 ';'" if enabled else "expected ';' after return statement")
            ui.command('NvimZhRaw')
            frame(ui, evidence, 'raw', "expected ';' after return statement")
            ui.command('wincmd p')
            ui.command('silent make!')
            frame(ui, evidence, 'quickfix-open', "return 语句后缺少 ';'" if enabled else "expected ';' after return statement")
            ui.command('cc')
            assert_lua(ui, "vim.fn.line('.') == 5 and vim.fn.col('.') == 18", 'CLANG_JUMP')
            ui.command('cclose')
            lua(ui, 'T.start()')
            assert_lua(ui, "T.diagnostic('expected_semi_after_stmt','syntax')", 'CLANGD_PUSH', timeout=12)
            lua(ui, "vim.diagnostic.open_float({scope='buffer'})")
            frame(ui, evidence, 'diagnostic', '有可用修复' if enabled else 'fix available')
            ui.send(b'\x1b')
            ui.command('NvimZhDiagnosticRaw')
            frame(ui, evidence, 'lsp-raw', 'expected_semi_after_stmt')
            ui.command('2')
            lua(ui, "vim.api.nvim_win_set_cursor(0,{2,4}); vim.lsp.buf.hover()")
            hover = frame(ui, evidence, 'hover', '函数 sum' if enabled else 'function sum', 'Parameters:')
            assert hover.count('Parameters:') >= 3, hover
            ui.send(b'\x1b')
            lua(ui, "vim.api.nvim_win_set_cursor(0,{5,13}); vim.lsp.buf.signature_help()")
            frame(ui, evidence, 'signature', '函数签名：clangd' if enabled else 'Signature Help: clangd')
            ui.send(b'\x1b')
            lua(ui, "vim.api.nvim_win_set_cursor(0,{5,18}); vim.lsp.buf.code_action({context={diagnostics={T.raw.syntax},only={'quickfix'}}})")
            title = "插入 ';'" if enabled else "insert ';'"
            action = frame(ui, evidence, 'action', title)
            match = re.search(r"(\d+): .*';'", action)
            assert match, action
            ui.send(match.group(1) + '\r')
            assert_lua(ui, "vim.api.nvim_buf_get_lines(0,4,5,false)[1]:sub(-1) == ';'", 'CLANGD_FIXED')
            ui.command('write')
            ui.command('silent make!')
            assert_lua(ui, 'vim.v.shell_error == 0 and #vim.fn.getqflist() == 0', 'CLANG_SUCCESS')
            lua(ui, 'T.pull()')
            assert_lua(ui, "T.raw['textDocument/diagnostic'].err.code == -32601", 'CLANGD_PULL_UNSUPPORTED')
            ui.command('edit 说明.cpp')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang++\\ -fsyntax-only\\ 说明.cpp')
            ui.command('silent lmake!')
            ui.command('lopen')
            frame(ui, evidence, 'location-note', '此前的定义在这里' if enabled else 'previous definition is here')
            ui.command('lclose')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0, T.client.id))')
            assert_lua(ui, "T.diagnostic('redefinition','related')", 'CLANGD_RELATED', timeout=12)
            lua(ui, "vim.diagnostic.open_float({scope='buffer'})")
            frame(ui, evidence, 'related', '此前的定义在这里' if enabled else 'Previous definition is here')
            ui.send(b'\x1b')
            ui.command('edit 补全.cpp')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id)); vim.lsp.completion.enable(true,T.client.id,0)')
            assert_lua(ui, "T.diagnostic('undeclared_var_use','completion')", 'COMPLETION_READY')
            lua(ui, 'vim.api.nvim_win_set_cursor(0,{3,16})')
            ui.send(b'i\x1b[15~')
            frame(ui, evidence, 'completion', 'sum', '[2 个重载]' if enabled else '[2 overloads]')
            ui.send(b'\x1b\x1b')
            ui.command('edit 检查.cpp')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id))')
            assert_lua(ui, "T.diagnostic('modernize-use-nullptr','tidy')", 'CLANGD_TIDY', timeout=12)
            lua(ui, "vim.diagnostic.open_float({scope='buffer'})")
            frame(ui, evidence, 'forwarded', '改用 nullptr' if enabled else 'Use nullptr',
                  '此范围内的首个形参' if enabled else 'The first parameter in the range')
            ui.send(b'\x1b')
            assert_lua(ui, "T.diagnostic('bugprone-easily-swappable-parameters','tidy_note')", 'CLANGD_TIDY_NOTE')
            ui.command('compiler nvim-zh-clang-tidy')
            ui.command('setlocal makeprg=clang-tidy\\ 检查.cpp\\ --checks=-*,modernize-use-nullptr,bugprone-easily-swappable-parameters\\ --\\ -std=c++20')
            ui.command('silent make!')
            ui.command('copen')
            frame(ui, evidence, 'tidy', '改用 nullptr' if enabled else 'use nullptr',
                  '此范围内的首个形参' if enabled else 'the first parameter in the range')
            ui.command('cclose')
            ui.command('setlocal makeprg=clang-tidy\\ 检查.cpp\\ --checks=-*,modernize-use-nullptr\\ --fix\\ --\\ -std=c++20')
            ui.command('silent make!')
            ui.command('checktime')
            assert_lua(ui, "vim.fn.readfile('检查.cpp')[1]:find('nullptr',1,true)", 'TIDY_FIXED')
            ui.command('setlocal makeprg=clang-tidy\\ 检查.cpp\\ --checks=-*,modernize-use-nullptr\\ --\\ -std=c++20')
            ui.command('silent make!')
            assert_lua(ui, 'vim.v.shell_error == 0 and #vim.fn.getqflist() == 0', 'TIDY_RECHECK')
            ui.command('edit 碰撞.c')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ 碰撞.c')
            ui.command('silent make!')
            ui.command('copen')
            frame(ui, evidence, 'collision', "expected ';' after return statement", reject=("return 语句后缺少",))
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.results.project_text == 1", 'PROJECT_TEXT')
            ui.command('edit 练习.cpp')
            lua(ui, 'T.notify_tweak()')
            frame(ui, evidence, 'notification', 'FunctionDecl', timeout=12)
            ui.send(b'\r')
            ui.command('edit 未知.c')
            ui.command('compiler nvim-zh-clang')
            lua(ui, 'vim.bo.makeprg=' + lua_literal(str(unknown) + ' -fsyntax-only 未知.c'))
            ui.command('silent make!')
            ui.command('copen')
            frame(ui, evidence, 'unknown', "expected ';' after return statement", reject=("return 语句后缺少",))
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.reason == 'unsupported_version'", 'UNKNOWN_VERSION')
            assert_lua(ui, "T.displayed.progress and T.displayed.progress.title == " + lua_literal('正在建立索引' if enabled else 'indexing'),
                       'INDEX_PROGRESS', timeout=12)
            assert_lua(ui, 'T.displayed.file ~= nil', 'CLANGD_FILE_STATUS', timeout=8)
            lua(ui, 'print(T.displayed.progress.title .. " · " .. T.displayed.file.state)')
            frame(ui, evidence, 'progress', '正在建立索引' if enabled else 'indexing')
            lua(ui, 'T.snapshot()')
            assert_lua(ui, "vim.fn.filereadable(vim.env.NVIM_ZH_TOOLCHAIN_RESULT)==1", 'TOOLCHAIN_CAPTURED')
        finally:
            (evidence / 'terminal.pty').write_bytes(ui.raw)
    data = json.loads(report.read_text())
    data['files'] = {name: (work / name).read_text() for name in ('练习.cpp', '检查.cpp', '碰撞.c')}
    return data


def normalize(data, base):
    uri = (base / 'work').as_uri()
    lower_escapes = re.sub(r'%[0-9A-F]{2}', lambda match: match[0].lower(), uri)
    return json.loads(json.dumps(data, ensure_ascii=False).replace(str(base / 'work'), '<project>')
                      .replace(uri, 'file://<project>').replace(lower_escapes, 'file://<project>')
                      .replace(str(base / 'clang'), '<unknown-clang>'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    if evidence.is_relative_to(ROOT):
        parser.error('--evidence must be outside the checkout')
    runs = []
    for name, enabled in (('原文', False), ('中文', True)):
        path = evidence / name
        path.mkdir(parents=True)
        runs.append(normalize(run(path, enabled), path))
        print(f'CLANG_TOOLCHAIN_TUI=PASS enabled={enabled}', flush=True)
    off, on = runs
    for section in ('raw', 'builds', 'files', 'capabilities'):
        assert off[section] == on[section], section
    for method in COMPARED_METHODS:
        original = [row for row in off['wire'] if row['method'] == method]
        localized = [row for row in on['wire'] if row['method'] == method]
        assert original and original == localized, method
    def ast_message(data):
        entry = next(row for row in data['wire'] if row['method'] == 'window/showMessage')
        return entry['params']['type'], re.sub(r'0x[0-9a-f]+', '<address>', entry['params']['message'])
    assert ast_message(off) == ast_message(on)
    assert [run['exit'] for run in on['builds']] == [1, 1, 0, 1, 0, 0, 0, 1, 1]
    (evidence / 'comparison.json').write_text(json.dumps(
        {'same': ['raw', 'builds', 'files', 'capabilities'], 'same_wire_methods': COMPARED_METHODS,
         'exit': [run['exit'] for run in on['builds']]},
        indent=2) + '\n')
    print('CLANG_TOOLCHAIN_TUI_DIFFERENTIAL=PASS')


if __name__ == '__main__':
    main()
