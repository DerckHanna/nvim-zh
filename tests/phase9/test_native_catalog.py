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


def synthetic_upstream(manifest: dict, headers: dict[str, str] | None = None) -> list[dict]:
    """A minimal catalog with the same keys as the pinned upstream catalog."""
    entries = [{'msgid': item['msgid'], 'msgstr': '', 'refs': list(item['refs'])}
               for item in manifest['gaps']]
    entries.append({'msgid': 'E484: Can\'t open file %s', 'msgstr': 'E484: 无法打开文件 %s'})
    entries.append({'msgid': '%d buffer unloaded', 'msgid_plural': '%d buffers unloaded',
                    'msgstr_plural': {0: '释放了 %d 个缓冲区'}})
    for item in manifest.get('intro', {}).get('messages', []):
        entries.append({'msgid': item['previous_msgid'], 'msgstr': '旧版提示'})
    return entries


class ManifestContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = nc.load_manifest(ROOT)

    def test_gap_and_exemption_counts(self) -> None:
        upstream = self.manifest['upstream']
        self.assertEqual(len(self.manifest['gaps']), upstream['untranslated'])
        self.assertEqual(upstream['messages'], upstream['translated'] + upstream['untranslated'])
        exempt = {item['msgid'] for item in self.manifest['exemptions']}
        gaps = {item['msgid'] for item in self.manifest['gaps']}
        self.assertTrue(exempt <= gaps)
        self.assertEqual(len(exempt), 12)

    def test_every_exemption_records_upstream_marker(self) -> None:
        for item in self.manifest['exemptions']:
            self.assertIn('do not translate', item['marker'])
            self.assertTrue(item['reason'])
            self.assertTrue(item['refs'])

    def test_supplement_plus_exemptions_cover_gaps_exactly(self) -> None:
        entries, _ = nc.parse_po(ROOT / self.manifest['supplement']['po'])
        supplement = {entry['msgid'] for entry in entries}
        gaps = {item['msgid'] for item in self.manifest['gaps']}
        exempt = {item['msgid'] for item in self.manifest['exemptions']}
        self.assertEqual(supplement | exempt, gaps)
        self.assertEqual(supplement & exempt, set())
        self.assertEqual(len(entries), self.manifest['supplement']['entries'])

    def test_repairs_and_prefix_repairs_are_consistent(self) -> None:
        entries, _ = nc.parse_po(ROOT / self.manifest['repairs']['po'])
        self.assertEqual(len(entries), self.manifest['repairs']['entries'])
        reconstructed = {entry['msgid'] for entry in entries}
        self.assertEqual(reconstructed, set(self.manifest['repairs']['runtime_msgids']))
        supplement, _ = nc.parse_po(ROOT / self.manifest['supplement']['po'])
        by_msgid = {entry['msgid']: entry for entry in supplement}
        for item in self.manifest['prefix_repairs']:
            self.assertIn(item['upstream_msgid'], by_msgid)
            self.assertRegex(item['prefix'], r'^E\d{2,5}: $')
            self.assertTrue(item['evidence'])
            runtime_key = item['prefix'] + by_msgid[item['upstream_msgid']]['msgid']
            self.assertNotIn(runtime_key, reconstructed)
        runtime_msgids = {item['runtime_literal'] for item in self.manifest['prefix_repairs']}
        self.assertEqual(len(runtime_msgids), len(self.manifest['prefix_repairs']))


class CheckContractTest(unittest.TestCase):
    def test_check_passes(self) -> None:
        result = nc.check(ROOT)
        self.assertEqual(result['gaps'], 130)
        self.assertEqual(result['supplement'], 118)
        self.assertEqual(result['exemptions'], 12)
        self.assertEqual(result['repairs'], 4)
        self.assertEqual(result['prefix_repairs'], 25)

    def test_placeholder_change_is_rejected(self) -> None:
        entry = {'msgid': 'E482: Can\'t open file %s for writing: %s',
                 'msgstr': 'E482: 无法打开文件 %s 进行写入'}
        with self.assertRaises(nc.NativeError):
            nc.check_entry(entry, Path('fixture.po'), [])

    def test_error_code_drop_is_rejected(self) -> None:
        entry = {'msgid': 'E482: Can\'t open file %s for writing: %s',
                 'msgstr': '无法打开文件 %s 进行写入：%s'}
        with self.assertRaises(nc.NativeError):
            nc.check_entry(entry, Path('fixture.po'), [])

    def test_forbidden_term_is_rejected(self) -> None:
        terms = nc.load_glossary(ROOT / 'translations/glossary/zh_CN.toml')
        entry = {'msgid': 'E676: No matching autocommands for buftype=%s buffer',
                 'msgstr': 'E676: 没有与 buftype=%s 的缓冲区匹配的自动命令'}
        with self.assertRaises(nc.NativeError):
            nc.check_entry(entry, Path('fixture.po'), terms)

    def test_untranslated_leftover_is_rejected(self) -> None:
        entry = {'msgid': 'too few bytes read', 'msgstr': 'too few bytes read'}
        with self.assertRaises(nc.NativeError):
            nc.check_entry(entry, Path('fixture.po'), [])


class MergeContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = nc.load_manifest(ROOT)
        self.terms = nc.load_glossary(ROOT / 'translations/glossary/zh_CN.toml')
        self.supplement, _ = nc.parse_po(ROOT / self.manifest['supplement']['po'])
        self.repairs, _ = nc.parse_po(ROOT / self.manifest['repairs']['po'])
        self.upstream = synthetic_upstream(self.manifest)

    def test_merge_covers_all_translatable_gaps(self) -> None:
        entries, stats = nc.merge(self.manifest, self.upstream, self.supplement, self.repairs)
        exempt = {item['msgid'] for item in self.manifest['exemptions']}
        self.assertEqual(stats['untranslated'], len(exempt))
        self.assertEqual(stats['untranslated'], stats['exemptions'])
        self.assertEqual(stats['messages'], len(self.upstream) + len(self.repairs)
                         + len(self.manifest['prefix_repairs']))
        for item in self.manifest['prefix_repairs']:
            self.assertIn(item['prefix'] + item['upstream_msgid'],
                          {entry['msgid'] for entry in entries})

    def test_render_is_deterministic_and_round_trips(self) -> None:
        entries, _ = nc.merge(self.manifest, self.upstream, self.supplement, self.repairs)
        first = nc.render_po(entries)
        second = nc.render_po(nc.merge(self.manifest, self.upstream, self.supplement, self.repairs)[0])
        self.assertEqual(first, second)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'roundtrip.po'
            path.write_text(first, encoding='utf-8', newline='\n')
            parsed, _ = nc.parse_po(path)
        self.assertEqual(len(parsed), len(entries))
        self.assertEqual({entry['msgid'] for entry in parsed}, {entry['msgid'] for entry in entries})

    def test_drift_is_rejected(self) -> None:
        upstream = synthetic_upstream(self.manifest)
        for entry in upstream:
            if entry['msgid'] == 'E482: Can\'t open file %s for writing: %s':
                entry['msgstr'] = 'E482: 上游已自行翻译'
        with self.assertRaises(nc.NativeError):
            nc.merge(self.manifest, upstream, self.supplement, self.repairs)


@unittest.skipUnless(shutil.which('msgfmt'), 'msgfmt (gettext) is required')
class BuildContractTest(unittest.TestCase):
    def test_build_compiles_and_reports_only_documented_exemptions(self) -> None:
        manifest = nc.load_manifest(ROOT)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            upstream = tmp / 'upstream.po'
            upstream.write_text(nc.render_po(synthetic_upstream(manifest), {'Content-Type': 'text/plain; charset=UTF-8'}),
                                encoding='utf-8', newline='\n')
            stats = nc.build(ROOT, manifest, upstream, tmp / 'out', expect_sha=None)
            self.assertEqual(stats['untranslated'], 12)
            self.assertEqual(stats['msgfmt']['untranslated'], 12)
            self.assertTrue((tmp / 'out/zh_CN.UTF-8/LC_MESSAGES/nvim.mo').is_file())
            first = stats['mo_sha256']
            second = nc.build(ROOT, manifest, upstream, tmp / 'out2', expect_sha=None)['mo_sha256']
            self.assertEqual(first, second, 'MO build must be reproducible')


LOCALE_SOURCE = Path('/usr/share/i18n/locales/zh_CN')


def _runtime_for(binary: str | None) -> Path | None:
    """$VIMRUNTIME of the binary under test, so the probe never uses a foreign tree."""
    if binary is None:
        return None
    out = subprocess.run(
        [binary, '--headless', '-u', 'NONE', '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
        capture_output=True, text=True, timeout=60,
        env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', '/tmp')})
    value = Path(out.stdout.strip())
    return value if (value / 'doc').is_dir() else None


def _probe_prefix(tmp: Path, mo: Path, runtime: Path) -> tuple[Path, dict]:
    """A copied binary + temp locale + temp state dir, so nothing host-side moves."""
    prefix = tmp / 'prefix'
    (prefix / 'bin').mkdir(parents=True)
    mo_dir = prefix / 'share/locale/zh_CN.UTF-8/LC_MESSAGES'
    mo_dir.mkdir(parents=True)
    shutil.copy2(shutil.which(NVIM), prefix / 'bin/nvim')
    shutil.copy2(mo, mo_dir / 'nvim.mo')
    locale_dir = tmp / 'locale'
    locale_dir.mkdir()
    subprocess.run(['localedef', '-i', 'zh_CN', '-f', 'UTF-8', str(locale_dir / 'zh_CN.UTF-8')],
                   check=True, capture_output=True)
    state = tmp / 'state'
    (state / 'nvim/shada').mkdir(parents=True)
    # Not a msgpack file: reading it reports E576, and the failed rewrite on exit
    # reports E136.
    (state / 'nvim/shada/main.shada').write_bytes(b'garbage-not-msgpack-\x01\x02\x03')
    env = {**os.environ, 'VIMRUNTIME': str(runtime), 'LOCPATH': str(locale_dir),
           'LC_ALL': 'zh_CN.UTF-8', 'XDG_STATE_HOME': str(state)}
    return prefix / 'bin/nvim', env


def _run_probe(binary: Path, env: dict, args: list[str]) -> str:
    process = subprocess.run([str(binary), '--headless', '-u', 'NONE', *args],
                             capture_output=True, text=True, env=env, timeout=60)
    return process.stdout + process.stderr


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
    that rebuild, and that every row COMPATIBILITY.md documents is real - the
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
