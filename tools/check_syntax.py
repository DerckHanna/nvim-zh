"""Syntax only: Neovim loadfile, Python AST and bash -n; no type analysis."""
import ast
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(os.environ['NVIM_ZH_ROOT'])
files = sorted(p for directory in ('lua', 'plugin', 'tests', 'tools', 'benchmarks')
               for p in (root / directory).rglob('*') if p.is_file())
counts = {'.py': 0, '.sh': 0, '.lua': 0}
for path in files:
    if path.suffix == '.py':
        ast.parse(path.read_bytes(), filename=str(path))
        counts['.py'] += 1
    elif path.suffix == '.sh':
        subprocess.run(['bash', '-n', str(path)], check=True)
        counts['.sh'] += 1
with tempfile.TemporaryDirectory(prefix='nvim-zh-syntax-') as tmp:
    paths = Path(tmp) / 'paths'
    paths.write_text('\n'.join(str(p) for p in files if p.suffix == '.lua') + '\n')
    counts['.lua'] = len(paths.read_text().splitlines())
    script = Path(tmp) / 'syntax.lua'
    script.write_text("for path in io.lines(vim.env.NVIM_ZH_SYNTAX_PATHS) do assert(loadfile(path)) end\n")
    subprocess.run([os.environ.get('NVIM_BIN', 'nvim'), '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', str(script)],
                   env={**os.environ, 'NVIM_ZH_SYNTAX_PATHS': str(paths)}, check=True)
print('SYNTAX=PASS ' + ' '.join(f'{ext[1:]}={count}' for ext, count in counts.items()) + ' type_analysis=false')
