"""Native (core gettext) catalog contracts for nvim-zh.

The suite is offline: it validates the translation resource in
translations/native/ against manifests/native.json, exercises merge/render with a
synthetic upstream catalog, and (when gettext and a usable locale are present)
compiles an MO and probes it through a copied Neovim binary in a temporary
prefix. No system file, locale, or Neovim installation is modified.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
sys.path.insert(0, str(ROOT / 'tools'))
import native_catalog as nc  # noqa: E402

NVIM = os.environ.get('NVIM_BIN', 'nvim')


from native_probe import LOCALE_SOURCE, _runtime_for, _probe_prefix, _run_probe
from test_native_catalog import synthetic_upstream

@unittest.skipUnless(os.environ.get('NVIM_ZH_TEST_NATIVE_RUNTIME') == '1',
                     'set NVIM_ZH_TEST_NATIVE_RUNTIME=1 to probe a real Neovim binary')
@unittest.skipUnless(shutil.which('msgfmt') and shutil.which('localedef') and shutil.which(NVIM),
                     'msgfmt, localedef and a Neovim binary are required')
@unittest.skipUnless(LOCALE_SOURCE.exists(), 'system zh_CN locale source is required')
class RuntimeProbeTest(unittest.TestCase):
    """Prove the built MO takes effect through a copied binary and a temp locale.

    Nothing outside the temporary directory is written: Neovim resolves its
    gettext directory from the binary prefix, so a copied binary plus a temp
    locale is enough to exercise the catalog without touching the host.

    Two catalogs are probed because they prove different things. A synthetic one
    built from the gap list proves the *supplement* is merged and applied. A
    rebuild from the cached pinned upstream proves the *shipped* MO is exactly
    that rebuild, and that every row docs/compatibility.md documents is real - the
    upstream-translated rows (E5005) only exist in the latter.
    """

    def test_supplemented_rows_survive_merge_and_apply(self) -> None:
        manifest = nc.load_manifest(ROOT)
        runtime = _runtime_for(shutil.which(NVIM))
        if runtime is None:
            self.skipTest('the Neovim binary does not report a usable $VIMRUNTIME')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            upstream = tmp / 'upstream.po'
            upstream.write_text(nc.render_po(synthetic_upstream(manifest), {'Content-Type': 'text/plain; charset=UTF-8'}),
                                encoding='utf-8', newline='\n')
            stats = nc.build(ROOT, manifest, upstream, tmp / 'out', expect_sha=None)
            self.assertEqual(stats['untranslated'], 12)
            binary, env = _probe_prefix(tmp, tmp / 'out/zh_CN.UTF-8/LC_MESSAGES/nvim.mo', runtime)
            output = _run_probe(binary, env,
                                ['-c', 'call writefile(["x"], "/proc/nope/f")', '-c', 'qa!'])
            # All three msgids come from the supplement (they are upstream gaps);
            # asserting only two of them let the third rot untested.
            self.assertIn('E482: 无法打开文件', output, output)
            self.assertIn('E576: 读取 ShaDa 文件时出错', output, output)
            self.assertIn('E136: 未重命名', output, output)
            self.assertNotIn('E482: Can\'t open file', output, output)
            # An upstream "# do not translate" exemption must stay English.
            script = tmp / 'exempt.lua'
            script.write_text('io.stderr:write("EXEMPT=" .. vim.fn.gettext("[Command Line]") .. "\\n")\n',
                              encoding='utf-8', newline='\n')
            other = _run_probe(binary, env, ['-l', str(script)])
            self.assertIn('EXEMPT=[Command Line]', other, other)

    def test_shipped_mo_is_the_pinned_rebuild_and_translates_every_documented_row(self) -> None:
        cached = ROOT / 'build/upstream/zh_CN.UTF-8.po'
        if not cached.is_file():
            self.skipTest(f'{cached} is missing; run `make sync-native` to cache the pinned upstream')
        shipped = ROOT / 'build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
        self.assertTrue(shipped.is_file(), shipped)
        manifest = nc.load_manifest(ROOT)
        runtime = _runtime_for(shutil.which(NVIM))
        if runtime is None:
            self.skipTest('the Neovim binary does not report a usable $VIMRUNTIME')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            stats = nc.build(ROOT, manifest, cached, tmp / 'out', expect_sha=None)
            # The shipped native artifact must equal a rebuild from the cached
            # pinned upstream. `make check-reproducible` only covers the UI Lua
            # catalogs, so without this a stale MO could ship unnoticed.
            self.assertEqual(
                stats['mo_sha256'], hashlib.sha256(shipped.read_bytes()).hexdigest(),
                'build/native MO is not the pinned rebuild; run `make build-native`')
            binary, env = _probe_prefix(tmp, tmp / 'out/zh_CN.UTF-8/LC_MESSAGES/nvim.mo', runtime)
            output = _run_probe(binary, env,
                                ['-c', 'call writefile(["x"], "/proc/nope/f")', '-c', 'qa!'])
            self.assertIn('E482: 无法打开文件', output, output)
            self.assertIn('E576: 读取 ShaDa 文件时出错', output, output)
            self.assertIn('E136: 未重命名', output, output)
            # E5005 is an upstream-translated row and one of its %s arguments is
            # the supplemented "key %s" fragment, so it needs a real scenario.
            script = tmp / 'e5005.lua'
            script.write_text(
                'local d = {}\n'
                'd.self = d\n'
                'local ok, err = pcall(vim.fn.msgpackdump, { d })\n'
                'io.stderr:write("MSGPACK_OK=" .. tostring(ok) .. " ERR=" .. tostring(err) .. "\\n")\n',
                encoding='utf-8', newline='\n')
            other = _run_probe(binary, env, ['-l', str(script)])
            self.assertIn('E5005: 无法 dump msgpackdump() 参数', other, other)
            self.assertIn("键 'self'", other, other)
            drift = _run_probe(binary, env, ['-i', 'NONE', '-l', str(Path(__file__).with_name('drift.lua'))])
            self.assertIn('NATIVE_DRIFT_RUNTIME=PASS', drift, drift)
            self.assertIn('Lua 回调：', drift, drift)
            self.assertIn('autocmd marker', drift, drift)
            self.assertIn('--server <address>    连接到此 Nvim 服务器', _run_probe(binary, env, ['--help']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
