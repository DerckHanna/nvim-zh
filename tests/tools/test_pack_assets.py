import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACK_ASSETS = ROOT / 'tools/pack_assets.py'


class PackAssetsSdk2Tests(unittest.TestCase):
    def _run(self, *args):
        return subprocess.run(
            [sys.executable, '-B', str(PACK_ASSETS), *args],
            cwd=ROOT, capture_output=True, text=True,
        )

    def test_sdk2_reproducible_and_independent_version_index(self):
        with tempfile.TemporaryDirectory(prefix='nvim-zh-pack-sdk2-') as tmp:
            base = Path(tmp)
            sdk1_dir = base / 'sdk1'
            sdk2_a = base / 'sdk2-a'
            sdk2_b = base / 'sdk2-b'
            r1 = self._run('--version', '0.1.0', '--sdk', '1', '--id', 'clang-tidy', '--output', str(sdk1_dir))
            self.assertEqual(r1.returncode, 0, r1.stderr)
            r2 = self._run('--version', '0.2.0', '--sdk', '2', '--id', 'clang-tidy',
                           '--index', str(sdk1_dir / 'catalog.json'), '--output', str(sdk2_a))
            self.assertEqual(r2.returncode, 0, r2.stderr)
            r3 = self._run('--version', '0.2.0', '--sdk', '2', '--id', 'clang-tidy',
                           '--index', str(sdk1_dir / 'catalog.json'), '--output', str(sdk2_b))
            self.assertEqual(r3.returncode, 0, r3.stderr)

            # Byte-for-byte reproducibility of SDK 2 asset and merged catalog.
            a_bytes = (sdk2_a / 'clang-tidy-zh_CN.json').read_bytes()
            b_bytes = (sdk2_b / 'clang-tidy-zh_CN.json').read_bytes()
            self.assertEqual(a_bytes, b_bytes)
            self.assertEqual((sdk2_a / 'catalog.json').read_bytes(), (sdk2_b / 'catalog.json').read_bytes())

            # Structure & size checks.
            sdk1_bytes = (sdk1_dir / 'clang-tidy-zh_CN.json').read_bytes()
            self.assertLess(len(a_bytes), len(sdk1_bytes))
            doc = json.loads(a_bytes.decode('utf-8'))
            self.assertEqual(doc['manifest']['sdk'], 2)
            self.assertEqual(doc['manifest']['version'], '0.2.0')
            self.assertEqual(doc['manifest']['files'], {})
            self.assertEqual(doc['files'], {})
            self.assertEqual(doc['catalog']['schema'], 2)
            self.assertEqual(doc['catalog']['domain'], 'clang-tidy')

            # Merged catalog preserves SDK 1 record untouched alongside SDK 2 0.2.0.
            merged = json.loads((sdk2_a / 'catalog.json').read_text(encoding='utf-8'))
            self.assertEqual(len(merged['packages']), 2)
            by_ver = {row['version']: row for row in merged['packages']}
            self.assertEqual(by_ver['0.1.0']['sdk'], 1)
            self.assertEqual(by_ver['0.2.0']['sdk'], 2)
            sdk1_cat = json.loads((sdk1_dir / 'catalog.json').read_text(encoding='utf-8'))
            self.assertEqual(by_ver['0.1.0'], sdk1_cat['packages'][0])

            # Same version with different SDK must be rejected by --index dedup.
            dup = self._run('--version', '0.1.0', '--sdk', '2', '--id', 'clang-tidy',
                            '--index', str(sdk1_dir / 'catalog.json'), '--output', str(base / 'dup'))
            self.assertNotEqual(dup.returncode, 0)
            self.assertIn('already has a different asset', dup.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
