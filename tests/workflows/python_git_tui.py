"""Exercise real pytest, Ruff and a Git merge conflict through Neovim's TUI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from adapter_tui import Terminal, assert_lua, lua_literal

INIT = """
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_ROOT)
vim.opt.shortmess:append('I')
vim.o.shell = '/bin/bash'
vim.o.shellcmdflag = '-o pipefail -c'
local enabled = vim.env.NVIM_ZH_LANGUAGE == 'on'
require('nvim-zh').setup({modules={core={enabled=false},help={enabled=enabled},
  ui={notify=enabled,prompts=enabled}, diagnostics={enabled=enabled}}})
function WorkEvidence(path)
  local items = vim.fn.getqflist()
  local rows = {}
  for index, item in ipairs(items) do
    if item.valid == 1 then
      rows[#rows+1] = { index=index, file=vim.fn.fnamemodify(vim.api.nvim_buf_get_name(item.bufnr), ':t'),
        line=item.lnum, column=item.col, text=item.text }
    end
  end
  assert(#rows > 0, vim.inspect(items))
  vim.fn.writefile({vim.json.encode({status=vim.v.shell_error, rows=rows})},path)
  print('WORK_EVIDENCE_READY')
end
vim.schedule(function() print('WORKFLOW_READY') end)
"""


def git(root, *args, status=0):
    result = subprocess.run(['git', '-C', str(root), *args], text=True, capture_output=True, timeout=10)
    assert result.returncode == status, result.stderr
    return result.stdout.strip()


def evidence(ui, path):
    ui.command('lua WorkEvidence(' + lua_literal(str(path)) + ')')
    ui.expect('WORK_EVIDENCE_READY')
    return json.loads(path.read_text())


def run(base, enabled):
    os.environ['NVIM_ZH_LANGUAGE'] = 'on' if enabled else 'off'
    files = {
        'test_算术.py': 'def test_addition():\n    assert 1 + 1 == 3\n',
        '检查.py': 'import os\nprint("用例")\n',
        '说明.txt': '共同版本\n'
    }
    with Terminal(base, INIT, rows=40, cols=140, files=files) as ui:
        ui.expect('WORKFLOW_READY')
        root = ui.cwd
        git(root, 'init', '-b', 'main')
        git(root, 'config', 'user.name', 'Workflow fixture')
        git(root, 'config', 'user.email', 'workflow@example.invalid')
        git(root, 'add', '说明.txt')
        git(root, 'commit', '-m', 'initial')
        git(root, 'switch', '-c', 'topic')
        (root / '说明.txt').write_text('主题分支\n')
        git(root, 'add', '说明.txt')
        git(root, 'commit', '-m', 'topic')
        git(root, 'switch', 'main')
        (root / '说明.txt').write_text('主分支\n')
        git(root, 'add', '说明.txt')
        git(root, 'commit', '-m', 'main')
        git(root, 'merge', 'topic', status=1)
        assert git(root, 'status', '--short', '--', '说明.txt').startswith('UU ')

        ui.command('help quickfix')
        ui.command("lua print(vim.fn.expand('%:t'))")
        ui.expect('quickfix.cnx' if enabled else 'quickfix.txt')
        ui.command('close')
        ui.command('edit test_算术.py')
        ui.command('compiler pytest')
        ui.command('make! test_算术.py')
        ui.expect('1 failed', 'Press ENTER', timeout=15)
        ui.send('\r')
        test = evidence(ui, base / 'pytest.json')
        assert test['status'] == 1 and any(r['line'] == 2 and r['file'] == 'test_算术.py' for r in test['rows']), test
        ui.command('copen')
        ui.expect('test_算术.py', 'assert (1 + 1) == 3')
        test_row = next(row for row in test['rows'] if row['line'] == 2 and row['file'] == 'test_算术.py')
        ui.command(f"cc {test_row['index']}")
        assert_lua(ui, "vim.fn.line('.')==2", 'TEST_LINE_2')
        ui.command('s/== 3/== 2/')
        ui.command('write')
        ui.command('make! test_算术.py')
        ui.expect('1 passed', 'Press ENTER', timeout=15)
        ui.send('\r')
        assert_lua(ui, "vim.v.shell_error==0", 'TEST_FIXED')

        ui.command('edit 检查.py')
        ui.command('compiler ruff')
        ui.command('make! 检查.py')
        ui.expect('F401', 'Press ENTER', timeout=15)
        ui.send('\r')
        lint = evidence(ui, base / 'ruff.json')
        assert lint['status'] == 1 and lint['rows'][0]['line'] == 1 and 'F401' in lint['rows'][0]['text'], lint
        ui.command('copen')
        ui.expect('检查.py', 'F401')
        ui.command(f"cc {lint['rows'][0]['index']}")
        assert_lua(ui, "vim.fn.line('.')==1", 'LINT_LINE_1')
        ui.command('1delete')
        ui.command('write')
        ui.command('make! 检查.py')
        ui.expect('Press ENTER', timeout=15)
        ui.send('\r')
        assert_lua(ui, "vim.v.shell_error==0", 'LINT_FIXED')

        ui.command('edit 说明.txt')
        ui.expect('<<<<<<< HEAD', '主分支', '主题分支')
        ui.command('vimgrep /<<<<<<< HEAD/g %')
        conflict = evidence(ui, base / 'merge.json')['rows']
        assert conflict[0]['line'] == 1 and conflict[0]['file'] == '说明.txt', conflict
        ui.command('cc')
        assert_lua(ui, "vim.fn.line('.')==1", 'CONFLICT_LINE_1')
        ui.command('silent %delete _')
        ui.send('i合并后的说明\x1b')
        ui.command('write')
        ui.command('silent !git add -- 说明.txt')
        assert_lua(ui, "vim.v.shell_error==0", 'CONFLICT_STAGED')
        assert not git(root, 'ls-files', '-u')
        assert git(root, 'show', ':说明.txt') == '合并后的说明'
        print(f'PYTHON_GIT_TUI=PASS zh={enabled} pytest_exit_1_0 ruff_F401_exit_1_0 git_conflict_exit_1_staged', flush=True)
        return {'test': test, 'lint': lint, 'conflict': conflict}


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='nvim-zh-python-git-') as directory:
        results = []
        for name, enabled in [('中文项目', True), ('英文项目', False)]:
            base = Path(directory) / name
            base.mkdir()
            results.append(run(base, enabled))
        assert results[0] == results[1], results
        print('PYTHON_GIT_DIFFERENTIAL=PASS locations_codes_messages_and_exit_status_equal')
