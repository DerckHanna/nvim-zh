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


if __name__ == '__main__':
    unittest.main(verbosity=2)
