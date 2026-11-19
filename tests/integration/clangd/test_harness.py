#!/usr/bin/env python3
"""Negative controls for the optional smoke harness itself."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import real_smoke as clangd_smoke  # noqa: E402


class ClangdReadTimeoutTests(unittest.TestCase):
    def test_partial_lsp_header_obeys_the_read_deadline(self):
        with tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-partial-read-') as tmp:
            root = Path(tmp)
            fake = root / 'fake-clangd'
            fake.write_text(
                f'#!{sys.executable}\n'
                'import sys, time\n'
                "sys.stdout.buffer.write(b'Content-Length: 2\\r\\n')\n"
                'sys.stdout.buffer.flush()\n'
                'time.sleep(30)\n',
                encoding='utf-8')
            fake.chmod(0o755)
            client = clangd_smoke.LspClient(str(fake), root)
            try:
                started = time.monotonic()
                with self.assertRaises(TimeoutError):
                    client.read(timeout=0.1)
                self.assertLess(time.monotonic() - started, 3)
            finally:
                client.process.kill()
                client.process.wait(timeout=5)
                for stream in (client.process.stdin, client.process.stdout, client.process.stderr):
                    if stream is not None:
                        stream.close()


class ObservationIntegrityTests(unittest.TestCase):
    def test_corpus_hash_mismatch_is_rejected(self):
        observation = json.loads(
            (ROOT / 'tests/fixtures/clangd/observed.json').read_text(encoding='utf-8'))
        first_name = sorted(observation['corpus_sha256'])[0]
        observation['corpus_sha256'][first_name] = '0' * 64
        nvim = os.environ.get('NVIM_BIN') or shutil.which('nvim')
        self.assertTrue(nvim, 'no nvim binary available for the observation contract')
        with tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-observation-gate-') as tmp:
            root = Path(tmp)
            path = root / 'observed.json'
            path.write_text(json.dumps(observation, ensure_ascii=False), encoding='utf-8')
            state = root / 'state'
            state.mkdir()
            result = subprocess.run([
                nvim, '--headless', '-u', 'NONE',
                '--cmd', f'set runtimepath^={ROOT}',
                '--cmd', 'runtime! plugin/nvim-zh.lua',
                '-l', str(ROOT / 'tests/contract/diagnostics/clangd_observation_spec.lua'),
            ], capture_output=True, text=True, timeout=120, env={
                **os.environ,
                'NVIM_ZH_ROOT': str(ROOT),
                'NVIM_ZH_TEST_CLANGD_OBSERVATION': str(path),
                'XDG_STATE_HOME': str(state),
            })
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('corpus hash mismatch', result.stdout + result.stderr)

    def test_successful_pull_accepts_source_and_rejects_translated_or_non_string_messages(self):
        observation = json.loads((ROOT / 'tests/fixtures/clangd/observed.json').read_text())
        original = next(raw for item in observation['push'] for raw in item['params']['diagnostics']
                        if raw['message'] == "Unknown type name 'MissingType'")
        for message, succeeds in ((original['message'], True), ("未知类型名 'MissingType'", False), (42, False)):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as tmp:
                raw = dict(original, message=message)
                observation['pull'] = [{'id': 20, 'result': {'kind': 'full', 'items': [raw]}}]
                observation['pull_status'] = 'passed'
                path = Path(tmp) / 'observed.json'
                path.write_text(json.dumps(observation))
                result = subprocess.run([os.environ.get('NVIM_BIN', 'nvim'), '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
                    '--cmd', f'set runtimepath^={ROOT}', '-l', str(ROOT / 'tests/contract/diagnostics/clangd_observation_spec.lua')],
                    env={**os.environ, 'NVIM_ZH_TEST_CLANGD_OBSERVATION': str(path)},
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
                if not succeeds:
                    self.assertIn('pull source data missing', result.stdout + result.stderr)


class PublicSeamGateTests(unittest.TestCase):
    def test_optimized_python_still_rejects_wrong_upstream_hashes(self):
        with tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-public-seam-gate-') as tmp:
            root = Path(tmp)
            path = ROOT / 'manifests/adapters/nvim-cmp.json'
            if not path.exists():
                self.skipTest('nvim-cmp inventory is absent')
            manifest = json.loads(path.read_text(encoding='utf-8'))
            names = set(manifest['targets']['baseline']['sources'])
            names.update(('lua/cmp/config/default.lua', 'lua/cmp/entry.lua'))
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('intentionally invalid upstream fixture\n', encoding='utf-8')
            result = subprocess.run(
                [sys.executable, str(ROOT / 'tests/upstream/nvim-cmp/cmp_seam.py')],
                capture_output=True, text=True, timeout=60,
                env={**os.environ, 'NVIM_ZH_TEST_NVIM_CMP': str(root), 'PYTHONOPTIMIZE': '1'})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('CMP_PUBLIC_SEAM_SMOKE=PASS', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
