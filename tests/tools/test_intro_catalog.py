"""Native welcome-screen translations, including an opt-in real terminal probe."""
from __future__ import annotations

import gettext
import json
import os
from pathlib import Path
import re
import select
import shutil
import struct
import subprocess
import tempfile
import time
import unittest

import test_native_catalog as native

ROOT = native.ROOT
INTRO = {
    'type  :help nvim<Enter>     if you are new! ': '输入  :help nvim<Enter>     新手必读！      ',
    'type  :checkhealth<Enter>   to optimize Nvim': '输入  :checkhealth<Enter>   优化 Nvim       ',
    'type  :q<Enter>             to exit         ': '输入  :q<Enter>             退出 Neovim     ',
    'type  :help<Enter>          for help        ': '输入  :help<Enter>          查看帮助        ',
    'type  :help news<Enter>     for v%s.%s notes ': '输入  :help news<Enter>     查看 v%s.%s 更新 ',
    'type  :help Kuwasha<Enter>  for information ': '输入  :help Kuwasha<Enter>  了解援助项目    ',
}
SHIPPED = ROOT / 'build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'


class IntroCatalogTests(unittest.TestCase):
    def test_shipped_mo_translates_exact_runtime_intro_keys(self):
        with SHIPPED.open('rb') as stream:
            catalog = gettext.GNUTranslations(stream)
        for msgid, expected in INTRO.items():
            with self.subTest(msgid=msgid):
                self.assertEqual(catalog.gettext(msgid), expected)
        self.assertEqual(catalog.gettext('Unrecognized intro message'), 'Unrecognized intro message')

    def test_intro_repairs_have_pinned_source_and_binary_evidence(self):
        manifest = native.nc.load_manifest(ROOT)
        info = manifest['intro']
        self.assertEqual(info['entries'], 6)
        self.assertEqual(info['source']['commit'], manifest['upstream']['commit'])
        self.assertEqual(info['source']['path'], 'src/nvim/version.c')
        self.assertRegex(info['source']['sha256'], r'^[0-9a-f]{64}$')
        self.assertRegex(info['source']['binary_sha256'], r'^[0-9a-f]{64}$')
        rows = info['messages']
        self.assertEqual({row['msgid'] for row in rows}, set(INTRO))
        self.assertTrue(all(row['source_line'] > 0 and row['previous_msgid'] != row['msgid'] for row in rows))
        entries, _ = native.nc.parse_po(ROOT / info['po'])
        self.assertEqual({e['msgid']: e['msgstr'] for e in entries}, INTRO)

    def test_check_rejects_intro_manifest_drift(self):
        for field, value in (('entries', 5), ('messages', [])):
            with self.subTest(field=field), tempfile.TemporaryDirectory(prefix='nvim-zh-intro-check-') as tmp:
                root = Path(tmp)
                for name in ('manifests/native.json', 'translations/native/zh_CN.po',
                             'translations/native/runtime_repairs.po', 'translations/native/intro.po',
                             'translations/glossary/zh_CN.toml'):
                    dest = root / name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / name, dest)
                path = root / 'manifests/native.json'
                manifest = json.loads(path.read_text())
                manifest['intro'][field] = value
                path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(native.nc.NativeError, 'intro:'):
                    native.nc.check(root)

    def test_merge_rejects_intro_collision_and_missing_legacy_key(self):
        manifest = native.nc.load_manifest(ROOT)
        upstream, _ = native.nc.parse_po(ROOT / 'build/upstream/zh_CN.UTF-8.po')
        supplement, _ = native.nc.parse_po(ROOT / manifest['supplement']['po'])
        repairs, _ = native.nc.parse_po(ROOT / manifest['repairs']['po'])
        intro, _ = native.nc.parse_po(ROOT / manifest['intro']['po'])
        legacy = manifest['intro']['messages'][0]['previous_msgid']
        cases = (upstream + [intro[0]], [e for e in upstream if e['msgid'] != legacy])
        for fixture in cases:
            with self.subTest(messages=len(fixture)):
                with self.assertRaisesRegex(native.nc.NativeError, 'intro'):
                    native.nc.merge(manifest, fixture, supplement, repairs, intro)


if __name__ == '__main__':
    unittest.main(verbosity=2)
