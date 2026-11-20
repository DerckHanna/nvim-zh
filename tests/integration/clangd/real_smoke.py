#!/usr/bin/env python3
"""Opt-in smoke against a real clangd; never downloads or installs software."""
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time

from pack_fixture import seed

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
CORPUS = ROOT / 'tests/fixtures/clangd/corpus'


class LspClient:
    def __init__(self, executable: str, root: Path):
        self.command = [executable, '--background-index=false', '--log=error']
        self.process = subprocess.Popen(
            self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=root, bufsize=0,
        )
        self.next_id = 0
        self._buffer = bytearray()

    def send(self, method: str, params=None, request: bool = False) -> int | None:
        message = {'jsonrpc': '2.0', 'method': method}
        if params is not None:
            message['params'] = params
        request_id = None
        if request:
            self.next_id += 1
            request_id = self.next_id
            message['id'] = request_id
        payload = json.dumps(message, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        data = f'Content-Length: {len(payload)}\r\n\r\n'.encode('ascii') + payload
        view = memoryview(data)
        while view:
            written = self.process.stdin.write(view)
            if written is None:
                raise BrokenPipeError('clangd stdin write made no progress')
            view = view[written:]
        self.process.stdin.flush()
        return request_id

    def _read_more(self, deadline: float) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('timed out waiting for a complete clangd message')
        ready, _, _ = select.select([self.process.stdout.fileno()], [], [], remaining)
        if not ready:
            raise TimeoutError('timed out waiting for a complete clangd message')
        chunk = os.read(self.process.stdout.fileno(), 65536)
        if not chunk:
            stderr = ''
            if self.process.poll() is not None:
                stderr = self.process.stderr.read().decode('utf-8', errors='replace')
            raise RuntimeError(f'clangd closed stdout: {stderr}')
        self._buffer.extend(chunk)

    def _readline(self, deadline: float) -> bytes:
        while True:
            index = self._buffer.find(b'\n')
            if index >= 0:
                line = bytes(self._buffer[:index + 1])
                del self._buffer[:index + 1]
                return line
            self._read_more(deadline)

    def _read_exact(self, length: int, deadline: float) -> bytes:
        while len(self._buffer) < length:
            self._read_more(deadline)
        payload = bytes(self._buffer[:length])
        del self._buffer[:length]
        return payload

    def read(self, timeout: float = 30) -> dict:
        deadline = time.monotonic() + timeout
        headers = {}
        while True:
            line = self._readline(deadline)
            if line in (b'\r\n', b'\n'):
                break
            key, value = line.decode('ascii').split(':', 1)
            headers[key.lower()] = value.strip()
        length = int(headers['content-length'])
        return json.loads(self._read_exact(length, deadline).decode('utf-8'))

    def close(self):
        if self.process.poll() is not None:
            return
        try:
            shutdown_id = self.send('shutdown', None, True)
            deadline = time.monotonic() + 5
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('timed out waiting for clangd shutdown')
                message = self.read(timeout=remaining)
                if message.get('id') == shutdown_id:
                    break
            self.send('exit')
            self.process.wait(timeout=5)
        except (BrokenPipeError, TimeoutError, subprocess.TimeoutExpired, RuntimeError):
            self.process.kill()
            self.process.wait(timeout=5)


def require(condition: bool, evidence) -> None:
    """Assertions must survive PYTHONOPTIMIZE and python -O."""
    if not condition:
        raise AssertionError(evidence)


def main() -> int:
    executable = os.environ.get('NVIM_ZH_TEST_CLANGD')
    if not executable:
        print('REAL_CLANGD_SMOKE=SKIP set NVIM_ZH_TEST_CLANGD=/absolute/path/to/clangd')
        return 0
    executable = str(Path(executable).resolve())
    version_text = subprocess.check_output([executable, '--version'], text=True).strip()
    corpus_files = sorted(CORPUS.glob('*.cpp'))
    if len(corpus_files) < 4:
        raise AssertionError('fixed clangd corpus must contain the C++ samples')

    with tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-clangd-smoke-') as tmp:
        work = Path(tmp)
        for source in corpus_files:
            shutil.copyfile(source, work / source.name)
        client = LspClient(executable, work)
        push, pull = [], []
        try:
            initialize_id = client.send('initialize', {
                'processId': None,
                'rootUri': work.as_uri(),
                'capabilities': {
                    'general': {'positionEncodings': ['utf-8']},
                    'textDocument': {
                        'publishDiagnostics': {'relatedInformation': True, 'versionSupport': True},
                        'diagnostic': {'relatedInformation': True},
                    },
                },
            }, True)
            initialize = None
            while initialize is None:
                message = client.read()
                if message.get('id') == initialize_id:
                    initialize = message
            client.send('initialized', {})
            for source in corpus_files:
                uri = (work / source.name).as_uri()
                text = source.read_text(encoding='utf-8')
                client.send('textDocument/didOpen', {'textDocument': {
                    'uri': uri, 'languageId': 'cpp', 'version': 1, 'text': text,
                }})
                client.send('workspace/didChangeConfiguration', {'settings': {}})
                pull_id = client.send('textDocument/diagnostic', {'textDocument': {'uri': uri}}, True)
                got_push = False
                got_pull = False
                while not (got_push and got_pull):
                    message = client.read()
                    if message.get('method') == 'textDocument/publishDiagnostics' and message['params']['uri'] == uri:
                        push.append(copy.deepcopy(message))
                        got_push = True
                    elif message.get('id') == pull_id:
                        pull.append(copy.deepcopy(message))
                        got_pull = True
        finally:
            client.close()

        pull_status = 'passed' if all('error' not in item for item in pull) else 'unsupported_method_not_found'
        if pull_status != 'passed':
            for response in pull:
                require(response.get('error', {}).get('code') == -32601, response)
        diagnostics = [d for item in push for d in item['params']['diagnostics']]
        # The corpus covers syntax errors, type conversion, overloads,
        # template instantiation, preprocessor errors, missing headers and
        # cross-file notes; every scenario must produce a diagnostic.
        require(len(diagnostics) >= 6, diagnostics)
        messages = {d['message'] for d in diagnostics}
        require(any(d['message'] == "Use of undeclared identifier '路径变量'" for d in diagnostics),
                'Chinese undeclared identifier missing')
        require(any(d.get('relatedInformation', [{}])[0].get('message') == 'Previous definition is here'
                    for d in diagnostics if d.get('relatedInformation')),
                'relatedInformation control missing')
        # Upstream wording is preserved for the reference sample; the Chinese
        # rendering is produced by the display layer, not by clangd.
        require(any('undeclared identifier' in message for message in messages),
                'undeclared identifier diagnostic missing')
        # The corpus covers the required C++ scenarios: syntax error, type
        # conversion, overload resolution, template instantiation note,
        # preprocessor error, missing header, clang-tidy warning and a
        # cross-file/redefinition note.
        scenarios = {
            'syntax error': lambda m: m.startswith('Expected'),
            'type conversion': lambda m: 'Cannot initialize' in m or 'incompatible' in m,
            'overload': lambda m: 'No matching function' in m,
            'template instantiation': lambda m: "Holder<int>" in m or 'in instantiation of' in m,
            'preprocessor': lambda m: 'Custom build failure message' in m,
            'missing header': lambda m: 'file not found' in m,
            'member lookup': lambda m: 'No member named' in m,
            'cross-file or redefinition note': lambda m: m == "Redefinition of 'repeated'",
        }
        for name, predicate in scenarios.items():
            require(any(predicate(message) for message in messages),
                    f'{name} diagnostic missing in {sorted(messages)}')
        if os.environ.get('NVIM_ZH_CLANGD_DEBUG'):
            print('CLANGD_DIAGNOSTIC_MESSAGES=' + json.dumps(sorted(messages), ensure_ascii=False))
        # The redefinition sample reports the previous definition through
        # relatedInformation rather than as a separate diagnostic message.
        require(any(d.get('relatedInformation') for d in diagnostics),
                'relatedInformation control missing')
        for diagnostic in diagnostics:
            for field in ('message', 'code', 'source', 'range', 'relatedInformation'):
                require(field in diagnostic, (field, diagnostic))

        observation = {
            'schema': 1,
            'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'clangd': {
                'version_text': version_text,
                # Only fields measured from this process belong in a new record.
                # Distribution, source commit and package hashes need external,
                # independently verifiable evidence; never invent fixed values.
                'distribution': None,
                'upstream_commit': None,
                'command': client.command,
                'ld_library_path': os.environ.get('LD_LIBRARY_PATH'),
                'package_sha256': {},
            },
            'initialize_result': initialize,
            'corpus_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in corpus_files},
            'push': push,
            'pull': pull,
            'pull_status': pull_status,
        }
        record = os.environ.get('NVIM_ZH_CLANGD_RECORD')
        observation_path = Path(record) if record else work / 'observed.json'
        rendered = json.dumps(observation, ensure_ascii=False, indent=2 if record else None)
        if record:
            rendered += '\n'
        raw_bytes = rendered.encode('utf-8')
        observation_path.write_bytes(raw_bytes)
        env = os.environ.copy()
        env['NVIM_ZH_ROOT'] = str(ROOT)
        env['NVIM_ZH_TEST_CLANGD_OBSERVATION'] = str(observation_path)
        seed(ROOT, Path(env['XDG_DATA_HOME']), 'clangd')
        command = [os.environ.get('NVIM_BIN', 'nvim'), '--headless', '-u', 'NONE',
                   '--cmd', f'set runtimepath^={ROOT}', '--cmd', 'runtime! plugin/nvim-zh.lua',
                   '-l', str(ROOT / 'tests' / 'contract' / 'diagnostics' / 'clangd_observation_spec.lua')]
        subprocess.run(command, env=env, check=True)
        require(observation_path.read_bytes() == raw_bytes,
                f'raw observation file changed during contract test: {observation_path}')
        editor = ROOT / 'tests' / 'integration' / 'clangd' / 'real_editor.lua'
        env['NVIM_ZH_TEST_CLANGD_WORK'] = str(work)
        env['NVIM_ZH_TEST_CLANGD'] = executable
        subprocess.run(command[:-1] + [str(editor)], env=env, check=True)
        print(f'REAL_CLANGD_VERSION={version_text.splitlines()[0]}')
        print(f'REAL_CLANGD_SMOKE=PASS push={len(push)}/{len(corpus_files)} '
              f'pull={pull_status} corpus={len(corpus_files)} '
              f'diagnostics={len(diagnostics)} raw=unchanged')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'REAL_CLANGD_SMOKE=FAIL {type(exc).__name__}: {exc}', file=sys.stderr)
        raise
