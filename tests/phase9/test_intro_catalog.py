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
    'type  :help nvim<Enter>     if you are new! ': '输入  :help nvim<Enter>     查看入门指南',
    'type  :checkhealth<Enter>   to optimize Nvim': '输入  :checkhealth<Enter>   检查运行环境',
    'type  :q<Enter>             to exit         ': '输入  :q<Enter>             退出 Neovim',
    'type  :help<Enter>          for help        ': '输入  :help<Enter>          查看帮助',
    'type  :help news<Enter>     for v%s.%s notes ': '输入  :help news<Enter>     查看 v%s.%s 更新',
    'type  :help Kuwasha<Enter>  for information ': '输入  :help Kuwasha<Enter>  了解援助项目',
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


def capture_intro(binary: Path, env: dict) -> bytes:
    """Capture the actual TUI, not gettext() calls made by a probe script."""
    import fcntl
    import pty
    import termios

    master, slave = pty.openpty()
    process = None
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 100, 0, 0))
        process = subprocess.Popen(
            [str(binary), '-u', 'NONE', '-i', 'NONE', '--noplugin'],
            stdin=slave, stdout=slave, stderr=slave, env={**env, 'TERM': 'xterm-256color'})
        os.close(slave)
        slave = -1
        data = bytearray()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                chunk = os.read(master, 65536)
                if not chunk:
                    break
                data.extend(chunk)
                # Answer terminal capability queries so startup never depends
                # on a real terminal emulator being attached to this PTY.
                if b'\x1b[6n' in chunk:
                    os.write(master, b'\x1b[1;1R')
                if b'\x1b[5n' in chunk:
                    os.write(master, b'\x1b[0n')
                if b'\x1b]11;?' in chunk:
                    os.write(master, b'\x1b]11;rgb:0000/0000/0000\x1b\\')
                if b'\x1b[c' in chunk or b'\x1b[0c' in chunk:
                    os.write(master, b'\x1b[?1;2c')
                if b'\x1b[>c' in chunk or b'\x1b[>0c' in chunk:
                    os.write(master, b'\x1b[>0;0;0c')
            # Colors and character-set switches can split ':help' between the
            # colon and the command. Strip only terminal controls, not text.
            visible = re.sub(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[()][0-2A-Z])', b'', data)
            if b'for information' in visible or '了解援助项目'.encode() in visible:
                return visible
            if process.poll() is not None:
                break
        raise AssertionError(f'welcome screen was not drawn within 8s: {bytes(data[-2000:])!r}')
    finally:
        if process is not None and process.poll() is None:
            try:
                os.write(master, b'\x1b:qa!\r')
                process.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                process.kill()
                process.wait(timeout=3)
        os.close(master)
        if slave >= 0:
            os.close(slave)


@unittest.skipUnless(os.environ.get('NVIM_ZH_TEST_NATIVE_RUNTIME') == '1', 'set NVIM_ZH_TEST_NATIVE_RUNTIME=1')
@unittest.skipUnless(os.name == 'posix' and shutil.which('localedef') and native.LOCALE_SOURCE.exists(),
                     'POSIX PTY and zh_CN locale source are required')
class IntroRuntimeTests(unittest.TestCase):
    def test_real_native_welcome_screen_uses_chinese_catalog(self):
        binary = shutil.which(native.NVIM)
        runtime = native._runtime_for(binary)
        if runtime is None:
            self.skipTest('Neovim runtime unavailable')
        version = subprocess.check_output([binary, '--version'], text=True).splitlines()[0]
        pinned = native.nc.load_manifest(ROOT)['upstream']['version']
        if version != 'NVIM v' + pinned:
            self.skipTest(f'intro screen baseline is pinned to {pinned}, running {version}')
        with tempfile.TemporaryDirectory(prefix='nvim-zh-intro-') as tmp:
            copied, env = native._probe_prefix(Path(tmp), SHIPPED, runtime)
            english = capture_intro(copied, {**env, 'LC_ALL': 'C.UTF-8'})
            self.assertIn(b'if you are new!', english)
            chinese = capture_intro(copied, env)
            for phrase in ('查看入门指南', '检查运行环境', '退出 Neovim', '查看帮助', '查看 v0.12 更新', '了解援助项目'):
                self.assertIn(phrase.encode(), chinese)
            self.assertNotIn(b'if you are new!', chinese)
            self.assertIn(b':help nvim', chinese)
            self.assertIn(b':checkhealth', chinese)


if __name__ == '__main__':
    unittest.main(verbosity=2)
