"""Drive the same Clang/clangd/clang-tidy project with Chinese on and off."""
from __future__ import annotations

import argparse
import hashlib
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
int indexing() { return 1; }
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
COLLISION = "expected ';' after return statement"
EXACT_KEY = 'expected expression'
FILES = {'练习.cpp': MAIN, '说明.cpp': NOTES, '检查.cpp': TIDY,
         '转发.cpp': 'int wrap(int *p, int v) { return p == 0 ? v : *p; }\n',
         '请求修复.cpp': 'int wrap(int *p, int v) { return p == 0 ? v : *p; }\n',
         '模板.cpp': (ROOT / 'tests/fixtures/clang-toolchain/corpus/template_notes.cpp').read_text(),
         '分析.cpp': (ROOT / 'tests/fixtures/clang-toolchain/corpus/analyzer.cpp').read_text()
         + 'int check_null(int *p) { return p == 0 ? 0 : *p; }\n',
         '补全.cpp': 'int sum(int x, int y);\nint sum(double x, double y);\nvoid test() { su; }\n',
         '项目.c': 'int value(void) { return 1; }\n',
         '碰撞.c': f'#error {COLLISION}\n#error {EXACT_KEY}\n',
         '重映射.c': f'#line 1 "项目.c"\n#error {COLLISION}\n',
         '续行.c': f'#er\\\nror {COLLISION}\n# /* comment\n*/ error {COLLISION}\n',
         '包含.c': f'#include "{EXACT_KEY}"\n',
         EXACT_KEY: '#include "内层.h"\n',
         '内层.h': '\tint value = ;\n',
         '未知.c': 'int main(void) { return 0 }\n',
         '.clang-tidy': 'Checks: "-*,modernize-use-nullptr,bugprone-easily-swappable-parameters,'
         'clang-analyzer-core.NullDereference"\n',
         '.clangd': 'Diagnostics:\n  ClangTidy:\n    FastCheckFilter: None\n'}
COMPARED_METHODS = ('textDocument/hover', 'textDocument/signatureHelp', 'textDocument/completion',
                    'textDocument/codeAction', 'workspace/executeCommand', 'workspace/applyEdit', 'workspace/symbol',
                    'textDocument/diagnostic',
                    'workspace/diagnostic', 'completionItem/resolve')


def lua(ui, command):
    ui.command('lua ' + command)


def frame(ui, evidence, name, *needles, **kwargs):
    text = ui.expect(*needles, **kwargs)
    (evidence / (name + '.txt')).write_text(text + '\n')
    return text


def choose_fix(ui, evidence, name, title):
    screen = frame(ui, evidence, name, title)
    match = re.search(r'^\s*(\d+): .*' + re.escape(title), screen, re.M)
    assert match, screen
    ui.send(match.group(1) + '\r')


def run(base, enabled, asset_directory):
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
        if asset_directory:
            filename = f'{tool}-zh_CN.json'
            content = (asset_directory / filename).read_bytes()
        else:
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
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'compile-failed', "return 语句后缺少 ';'" if enabled else "expected ';' after return statement")
            ui.command('NvimZhRaw')
            frame(ui, evidence, 'raw', "expected ';' after return statement")
            ui.command('wincmd p')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
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
            choose_fix(ui, evidence, 'action', "插入 ';'" if enabled else "insert ';'")
            assert_lua(ui, "vim.api.nvim_buf_get_lines(0,4,5,false)[1]:sub(-1) == ';'", 'CLANGD_FIXED')
            ui.command('write')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            assert_lua(ui, 'vim.v.shell_error == 0 and #vim.fn.getqflist() == 0', 'CLANG_SUCCESS')
            lua(ui, 'T.pull()')
            assert_lua(ui, "T.raw['textDocument/diagnostic'].err.code == -32601", 'CLANGD_PULL_UNSUPPORTED')
            assert_lua(ui, "T.symbol()", 'CLANGD_SYMBOL', timeout=12)
            ui.command('edit 说明.cpp')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang++\\ -fsyntax-only\\ 说明.cpp')
            ui.command('silent lmake!')
            lua(ui, "assert(T.compiler_ready())")
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
            frame(ui, evidence, 'completion', 'sum', '[2 overloads]')
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
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'tidy', '改用 nullptr' if enabled else 'use nullptr',
                  '此范围内的首个形参' if enabled else 'the first parameter in the range')
            ui.command('cclose')
            ui.command('setlocal makeprg=clang-tidy\\ 检查.cpp\\ --checks=-*,modernize-use-nullptr\\ --fix\\ --\\ -std=c++20')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('checktime')
            assert_lua(ui, "vim.fn.readfile('检查.cpp')[1]:find('nullptr',1,true)", 'TIDY_FIXED')
            ui.command('setlocal makeprg=clang-tidy\\ 检查.cpp\\ --checks=-*,modernize-use-nullptr\\ --\\ -std=c++20')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            assert_lua(ui, 'vim.v.shell_error == 0 and #vim.fn.getqflist() == 0', 'TIDY_RECHECK')
            ui.command('edit 转发.cpp')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id))')
            assert_lua(ui, "T.diagnostic('modernize-use-nullptr','forwarded_fix')", 'FORWARDED_FIX_READY')
            lua(ui, "vim.api.nvim_win_set_cursor(0,{1,T.raw.forwarded_fix.range.start.character}); "
                    "vim.lsp.buf.code_action({context={diagnostics={T.raw.forwarded_fix},only={'quickfix'}}})")
            choose_fix(ui, evidence, 'forwarded-action', "将 '0' 改为 'nullptr'" if enabled else "change '0' to 'nullptr'")
            assert_lua(ui, "vim.api.nvim_get_current_line():find('p == nullptr',1,true)", 'FORWARDED_FIXED')
            ui.command('write')
            assert_lua(ui, 'vim.wait(10000,function() return #vim.diagnostic.get(0)==0 end,25)', 'FORWARDED_RECHECK')
            ui.command('edit 请求修复.cpp')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id))')
            assert_lua(ui, "T.diagnostic('modernize-use-nullptr','apply_edit')", 'APPLY_EDIT_READY')
            lua(ui, 'T.apply_edit()')
            assert_lua(ui, "vim.api.nvim_get_current_line():find('p == nullptr',1,true)", 'APPLIED_WORKSPACE_EDIT')
            ui.command('write')
            assert_lua(ui, 'vim.wait(10000,function() return #vim.diagnostic.get(0)==0 end,25)', 'APPLY_EDIT_RECHECK')
            ui.command('edit 分析.cpp')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id))')
            assert_lua(ui, 'T.analyzer_push()', 'NO_FORWARDED_ANALYZER', timeout=12)
            ui.command('compiler nvim-zh-clang-tidy')
            ui.command('setlocal makeprg=clang-tidy\\ 分析.cpp\\ --checks=-*,clang-analyzer-core.NullDereference\\ --\\ -std=c++20')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            ui.command('resize 17')
            frame(ui, evidence, 'analyzer-path',
                  "解引用了空指针（从变量 'ptr' 读取）" if enabled else "Dereference of null pointer (loaded from variable 'ptr')",
                  "'ptr' 初始化为空指针" if enabled else "'ptr' initialized to a null pointer value",
                  "假定 'condition' 为真" if enabled else "Assuming 'condition' is true",
                  "进入条件为真的分支" if enabled else "Taking true branch")
            ui.command('cc 2')
            assert_lua(ui, "vim.fn.expand('%:t') == '分析.cpp' and vim.fn.line('.') == 4", 'ANALYZER_JUMP')
            ui.command('cclose')
            ui.command('edit 碰撞.c')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ 碰撞.c')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'collision', COLLISION, EXACT_KEY, reject=("return 语句后缺少", "缺少表达式"))
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.results.project_text == 2", 'PROJECT_TEXT')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id))')
            assert_lua(ui, "T.diagnostic('pp_hash_error','pp_collision',1)", 'PREPROCESSOR_COLLISION')
            lua(ui, "vim.diagnostic.open_float({scope='line',pos=1})")
            frame(ui, evidence, 'collision-lsp', EXACT_KEY.capitalize(), reject=("缺少表达式",))
            ui.send(b'\x1b')
            ui.command('edit 续行.c')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ 续行.c')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'continued-directive', COLLISION, reject=("return 语句后缺少",))
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.results.project_text == 2", 'CONTINUED_PROJECT_TEXT')
            ui.command('edit 重映射.c')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ 重映射.c')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'presumed-location', '项目.c', COLLISION, reject=("return 语句后缺少",))
            ui.command('cc')
            assert_lua(ui, "vim.fn.expand('%:t') == '项目.c' and vim.fn.line('.') == 1", 'PRESUMED_JUMP')
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.results.unverified_location == 1", 'PRESUMED_SOURCE')
            ui.command('edit 包含.c')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ 包含.c')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            stack = '包含自' if enabled else 'In file included from'
            frame(ui, evidence, 'include-stack', f'{stack} 包含.c:1', f'{stack} ./{EXACT_KEY}:1',
                  '缺少表达式' if enabled else 'expected expression')
            lua(ui, "vim.fn.setqflist({}, 'a', { idx = 2 })")
            ui.command('NvimZhRaw')
            frame(ui, evidence, 'include-stack-raw', f'In file included from ./{EXACT_KEY}:1:')
            ui.command('cclose')
            ui.command('cc 3')
            assert_lua(ui, "vim.fn.expand('%:t') == '内层.h' and vim.fn.line('.') == 1", 'INCLUDE_JUMP')
            ui.command('edit 项目.c')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ -std=c17+\\ 项目.c')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'compiler-options',
                  "error: '-std=c17+' 中的值 'c17+' 无效" if enabled else "error: invalid value 'c17+' in '-std=c17+'",
                  "使用 'c89'、'c90' 或 'iso9899:1990'" if enabled else "use 'c89', 'c90', or 'iso9899:1990'")
            ui.command('cclose')
            lua(ui, 'vim.bo.makeprg=' + lua_literal('clang -fsyntax-only "O\'Neil 不存在.c"'))
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'quoted-path',
                  "没有该文件或目录：'O'Neil 不存在.c'" if enabled else "no such file or directory: 'O'Neil 不存在.c'")
            ui.command('cclose')
            ui.command('setlocal makeprg=clang\\ -fsyntax-only\\ -fno-caret-diagnostics\\ 未知.c')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'custom-diagnostics', COLLISION, reject=("return 语句后缺少",))
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.reason == 'unverified_interface'",
                           'CUSTOM_DIAGNOSTICS')
            ui.command('edit 模板.cpp')
            ui.command('compiler nvim-zh-clang')
            ui.command('setlocal makeprg=clang++\\ -fsyntax-only\\ -std=c++20\\ 模板.cpp')
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            ui.command('resize 23')
            frame(ui, evidence, 'template-notes',
                  "类模板 'Pair' 的模板实参太少" if enabled else "too few template arguments for class template 'Pair'",
                  "类型 'int' 没有成员" if enabled else "type 'int' cannot be used prior",
                  "无法访问不完整类型 'Tag' 的成员" if enabled else "member access into incomplete type 'Tag'")
            ui.command('cclose')
            lua(ui, 'assert(vim.lsp.buf_attach_client(0,T.client.id))')
            assert_lua(ui, "T.diagnostic('template_arg_list_different_arity','template_arity')", 'TEMPLATE_ARITY')
            lua(ui, "local _, win=vim.diagnostic.open_float({scope='line',pos=1}); T.template_float=win")
            frame(ui, evidence, 'template-related',
                  "类模板 'Pair' 的模板实参太少" if enabled else "Too few template arguments for class template 'Pair'",
                  "模板在此处声明" if enabled else "Template is declared here")
            lua(ui, "vim.api.nvim_win_close(T.template_float, true)")
            assert_lua(ui, "T.diagnostic('ovl_no_viable_function_in_call','constraint')", 'TEMPLATE_CONSTRAINT')
            lua(ui, "vim.diagnostic.open_float({scope='line',pos=4})")
            frame(ui, evidence, 'constraint-related',
                  "因为 'int' 不满足 'C'" if enabled else "Because 'int' does not satisfy 'C'",
                  "类型 'int' 没有成员" if enabled else "type 'int' cannot be used prior")
            ui.send(b'\x1b')
            ui.command('edit 练习.cpp')
            lua(ui, 'T.notify_tweak()')
            frame(ui, evidence, 'notification', 'FunctionDecl', timeout=12)
            ui.send(b'\r')
            ui.command('edit 未知.c')
            ui.command('compiler nvim-zh-clang')
            lua(ui, 'vim.bo.makeprg=' + lua_literal(str(unknown) + ' -fsyntax-only 未知.c'))
            ui.command('silent make!')
            lua(ui, "assert(T.compiler_ready())")
            ui.command('copen')
            frame(ui, evidence, 'unknown', "expected ';' after return statement", reject=("return 语句后缺少",))
            ui.command('cclose')
            if enabled:
                assert_lua(ui, "require('nvim-zh').status().compiler.last.reason == 'unsupported_version'", 'UNKNOWN_VERSION')
            assert_lua(ui, "T.display_status() and T.displayed.progress and T.displayed.progress.title == " + lua_literal('正在建立索引' if enabled else 'indexing'),
                       'INDEX_PROGRESS', timeout=12)
            assert_lua(ui, 'T.displayed.file ~= nil', 'CLANGD_FILE_STATUS', timeout=8)
            lua(ui, 'print(T.displayed.progress.title .. " · " .. T.displayed.file.state)')
            frame(ui, evidence, 'progress', '正在建立索引' if enabled else 'indexing')
            lua(ui, 'T.snapshot()')
            assert_lua(ui, "vim.fn.filereadable(vim.env.NVIM_ZH_TOOLCHAIN_RESULT)==1", 'TOOLCHAIN_CAPTURED')
        finally:
            (evidence / 'terminal.pty').write_bytes(ui.raw)
    data = json.loads(report.read_text())
    data['files'] = {name: (work / name).read_text() for name in FILES}
    data['attachments'] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted(candidate.glob('*.json'))}
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
    parser.add_argument('--assets', type=Path, help='use these candidate files for both terminal sessions')
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    if evidence.is_relative_to(ROOT):
        parser.error('--evidence must be outside the checkout')
    runs = []
    for name, enabled in (('原文', False), ('中文', True)):
        path = evidence / name
        path.mkdir(parents=True)
        runs.append(normalize(run(path, enabled, args.assets), path))
        print(f'CLANG_TOOLCHAIN_TUI=PASS enabled={enabled}', flush=True)
    off, on = runs
    compared = ['raw', 'builds', 'files', 'capabilities', 'attachments']
    for section in compared:
        assert off[section] == on[section], section
    for method in COMPARED_METHODS:
        original = [row for row in off['wire'] if row['method'] == method]
        localized = [row for row in on['wire'] if row['method'] == method]
        assert original and original == localized, method
    def ast_message(data):
        entry = next(row for row in data['wire'] if row['method'] == 'window/showMessage')
        return entry['params']['type'], re.sub(r'0x[0-9a-f]+', '<address>', entry['params']['message'])
    assert ast_message(off) == ast_message(on)
    assert [run['exit'] for run in on['builds']] == [1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1]
    (evidence / 'comparison.json').write_text(json.dumps(
        {'same': compared, 'same_wire_methods': COMPARED_METHODS, 'attachments': on['attachments'],
         'exit': [run['exit'] for run in on['builds']]},
        indent=2) + '\n')
    print('CLANG_TOOLCHAIN_TUI_DIFFERENTIAL=PASS')


if __name__ == '__main__':
    main()
