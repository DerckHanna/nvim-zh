"""A runtime that is not the pinned baseline must be skipped, not compared.

0.11.5 does not ship 10 of the pinned 133 help documents and nightly dropped
pi_zip.txt, so asserting pinned 0.12.6 text against those runtimes reports
version drift as parity breakage. The gate is exercised here through a fake nvim
that reports a different version, so the real check runs without a second
Neovim installation.

Classification must be conservative in both directions: a runtime that merely
*claims* the pinned version is verified against the pinned text (three spread-out
documents, not one), and a prerelease build that claims the pinned version is a
hard error instead of a silent "unpinned" that skips every comparison.
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / 'tests/phase8/check_help_parity.py'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_help_parity as parity  # noqa: E402


class HelpParityPinGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-parity-skip-')
        self.dir = Path(self.tmp.name)
        (self.dir / 'state').mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def _fake_nvim(self, version, fail_version=False):
        runtime = self.dir / 'runtime'
        (runtime / 'doc').mkdir(parents=True, exist_ok=True)
        shim = self.dir / 'nvim'
        version_probe = ('  exit 1\n' if fail_version else
                         f'  echo "NVIM v{version}"\n  exit 0\n')
        shim.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = "--version" ]; then\n'
            f'{version_probe}'
            'fi\n'
            f'echo "{runtime}"\n',
            encoding='utf-8')
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
        return shim

    def _run_shim(self, shim):
        env = {key: value for key, value in os.environ.items() if key != 'VIMRUNTIME'}
        env.update({
            'NVIM_ZH_ROOT': str(ROOT),
            'PYTHONDONTWRITEBYTECODE': '1',
            'XDG_STATE_HOME': str(self.dir / 'state'),
        })
        return subprocess.run(
            [sys.executable, str(CHECKER), '--nvim', str(shim)],
            capture_output=True, text=True, env=env, timeout=120)

    def _run(self, version):
        return self._run_shim(self._fake_nvim(version))

    def test_unpinned_runtime_is_skipped(self):
        result = self._run('0.11.5')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HELP_PARITY=SKIP', result.stdout)
        self.assertIn('pinned=0.12.6', result.stdout)
        self.assertIn('runtime=0.11.5', result.stdout)
        self.assertNotIn('PARITY_ERROR', result.stdout)

    def test_version_probe_failure_is_a_hard_error(self):
        result = self._run_shim(self._fake_nvim('0.12.6', fail_version=True))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('HELP_PARITY=SKIP', result.stdout)

    def test_pinned_runtime_still_compares(self):
        # Negative control: with the pinned version the gate must not fire, so
        # the comparison really runs (and here fails on the empty fake runtime)
        # instead of silently skipping everything.
        result = self._run('0.12.6')
        self.assertNotIn('HELP_PARITY=SKIP', result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_pinned_runtime_with_wrong_content_is_rejected(self):
        # A self-reported version is not evidence: the runtime text has to match
        # the pinned sha256 before any parity comparison is trusted.
        shim = self._fake_nvim('0.12.6')
        (self.dir / 'runtime' / 'doc' / 'api-ui-events.txt').write_text('not the pinned text\n', encoding='utf-8')
        result = self._run_shim(shim)
        self.assertIn('reason=pinned_runtime_content_mismatch', result.stdout)
        self.assertNotIn('HELP_PARITY=SKIP', result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_probe_covers_more_than_the_first_document(self):
        self.assertEqual(parity.probe_documents([]), [])
        names = ['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']
        probes = parity.probe_documents(names)
        self.assertGreater(len(probes), 1, 'one document must not be the only baseline probe')
        self.assertEqual(probes[0], 'a.txt')
        self.assertEqual(probes[-1], 'e.txt')
        # A runtime that only ships part of the corpus still gets a spread probe,
        # and duplicates collapse.
        self.assertEqual(parity.probe_documents(['b.txt', 'd.txt']), ['b.txt', 'd.txt'])
        self.assertEqual(parity.probe_documents(['c.txt']), ['c.txt'])


class PinnedVersionClassificationTests(unittest.TestCase):
    """The Lua specs must not silently downgrade a prerelease pinned build."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-version-gate-')
        self.dir = Path(self.tmp.name)
        (self.dir / 'state').mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def _stub_version_nvim(self, major, minor, patch, prerelease):
        real = os.environ.get('NVIM_BIN') or shutil.which('nvim')
        self.assertTrue(real, 'no nvim binary available to drive the Lua specs')
        literal = 'nil' if prerelease is None else repr(prerelease)
        shown = prerelease if prerelease is not None else ''
        stub = (
            'lua vim.version=setmetatable('
            f'{{major={major},minor={minor},patch={patch},prerelease={literal}}},'
            '{__call=function() return vim.version end,'
            f"__tostring=function() return '{major}.{minor}.{patch}{shown}' end}})"
        )
        shim = self.dir / 'nvim-stub-version'
        shim.write_text(f'#!/bin/sh\nexec "{real}" --cmd "{stub}" "$@"\n', encoding='utf-8')
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
        return shim

    def _run_spec(self, shim, spec):
        return subprocess.run(
            [str(shim), '--headless', '-u', 'NONE',
             '--cmd', f'set runtimepath^={ROOT}', '-l', str(spec)],
            capture_output=True, text=True, timeout=180,
            env={**os.environ, 'NVIM_ZH_ROOT': str(ROOT), 'XDG_STATE_HOME': str(self.dir / 'state')})

    def _specs(self):
        return (ROOT / 'tests/phase1/04_docs_spec.lua',
                ROOT / 'tests/phase8/01_help_catalog_spec.lua',
                ROOT / 'tests/phase8/02_lsp_ui_text_spec.lua')

    def test_prerelease_build_claiming_the_pinned_version_is_a_hard_error(self):
        shim = self._stub_version_nvim(0, 12, 6, 'dev')
        for spec in self._specs():
            result = self._run_spec(shim, spec)
            self.assertNotEqual(result.returncode, 0,
                                f'{spec.name} accepted a prerelease build as the pinned baseline')
            self.assertIn('pinned/unpinned cannot be decided',
                          result.stderr + result.stdout, spec.name)

    def test_unpinned_prerelease_build_still_runs_the_shared_contract(self):
        # Negative control so the gate is not simply "always error": a prerelease
        # of a *different* version is the ordinary unpinned case (nightly) and
        # must still execute the runtime-independent contract.
        shim = self._stub_version_nvim(0, 13, 0, 'dev')
        result = self._run_spec(shim, ROOT / 'tests/phase1/04_docs_spec.lua')
        self.assertEqual(result.returncode, 0, result.stderr)
        # `nvim -l script` writes print() output to stderr, not stdout.
        self.assertIn('DOCS_SPEC=PASS', result.stdout + result.stderr)
        self.assertNotIn('pinned/unpinned cannot be decided', result.stderr + result.stdout)


if __name__ == '__main__':
    unittest.main()
