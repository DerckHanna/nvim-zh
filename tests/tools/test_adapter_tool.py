import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import adapter_manifest as manifest
import adapter_tool


class AdapterToolTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ['NVIM_ZH_ROOT'])
        self.scratch = tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-tool-')
        self.addCleanup(self.scratch.cleanup)
        self.temp = Path(self.scratch.name)

    def fixture(self):
        for folder in ('manifests', 'lua', 'translations', 'tests'):
            shutil.copytree(self.root / folder, self.temp / folder)
        return self.temp

    def tool(self, *args, root=None):
        result = subprocess.run([sys.executable, str(self.root / 'tools/adapter_tool.py'),
                                 '--root', str(root or self.root), *args, '--json'],
                                capture_output=True, text=True, timeout=20)
        return result.returncode, json.loads(result.stdout)

    def test_scaffold_and_remove_draft(self):
        root = self.fixture()
        code, report = self.tool('scaffold', 'tool-fixture', '--repo', 'https://github.com/example/nvim',
                                 '--commit', 'a' * 40, root=root)
        self.assertEqual(code, 0, report)
        self.assertEqual(report['status'], 'draft')
        draft = root / report['file']
        self.assertTrue(draft.is_file())
        self.assertNotIn('tool-fixture', manifest.index_text(manifest.validate(root)))
        code, plan = self.tool('remove', 'tool-fixture', '--plan', root=root)
        self.assertEqual(code, 0, plan)
        self.assertEqual(plan['files'], ['manifests/adapters/tool-fixture.json'])
        self.assertTrue(draft.is_file())
        code, report = self.tool('remove', 'tool-fixture', root=root)
        self.assertEqual(code, 0, report)
        self.assertFalse(draft.exists())
        self.assertEqual((root / manifest.INDEX).read_text(), manifest.index_text(manifest.validate(root)))

    def test_missing_tui_contract_is_a_hard_error(self):
        root = self.fixture()
        choices = [spec for spec in manifest.load(root).values() if spec['status'] == 'implemented']
        if not choices:
            self.skipTest('no implemented adapter to invalidate')
        obj = choices[0]
        path = root / 'manifests/adapters' / (obj['id'] + '.json')
        obj['scenarios'] = {}
        path.write_text(json.dumps(obj))
        with self.assertRaisesRegex(manifest.AdapterError, 'all enabled surfaces require a TUI scenario'):
            manifest.validate(root)

    def test_baseline_lock_selects_dependency_and_rejects_wrong_source(self):
        specs = manifest.validate(self.root)
        choices = [spec for spec in specs.values() if spec['targets']['baseline']['dependencies']]
        if not choices:
            self.skipTest('no adapter dependencies to verify')
        spec = choices[0]
        id = spec['id']
        lock = manifest.target_lock(specs, manifest.dependencies(self.root), id, 'baseline')
        self.assertLessEqual(set(spec['targets']['baseline']['dependencies']), lock['sources'].keys())
        dap = lock['sources'][id]
        checkout = self.temp / id / dap['commit']
        checkout.mkdir(parents=True)
        first = checkout / next(iter(dap['sources']))
        first.parent.mkdir(parents=True)
        first.write_text('wrong')
        with self.assertRaisesRegex(manifest.AdapterError, 'source digest mismatch'):
            manifest.checked_source(self.temp, id, dap)

    def test_manifest_can_build_a_one_adapter_index_without_registration_code(self):
        adapters = manifest.load(self.root)
        ids = [id for id, spec in adapters.items() if spec['status'] != 'draft']
        if not ids:
            self.skipTest('no adapter is registered')
        id = ids[0]
        index = manifest.index_text({id: adapters[id]})
        self.assertIn(f'"{id}":{{', index)
        for other in ids[1:]:
            self.assertNotIn(f'"{other}":{{', index)

    def test_case_runs_in_private_nvim_directories(self):
        env = adapter_tool.env_for(self.root, self.temp, {'nvim-tree': self.temp}, 'nvim')
        for key in ('STATE', 'DATA', 'CONFIG', 'CACHE', 'RUNTIME'):
            directory = Path(env[f'XDG_{key}_HOME'])
            self.assertEqual(directory.parent, self.temp)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(env['NVIM_ZH_TEST_NVIM_TREE'], str(self.temp))

    def test_help_excerpt_preserves_example_and_link(self):
        original = '*section* |example| >lua\n  print("original")\n<\n'
        excerpt = '*section* 说明 |example| >lua\n  print("original")\n<\n'
        check = adapter_tool.check_help_excerpt
        check('fixture', 'example.cnx', original, excerpt, {'section', 'example.cnx'})
        with self.assertRaisesRegex(manifest.AdapterError, 'Help example'):
            check('fixture', 'example.cnx', original, excerpt.replace('original', 'changed'), {'section'})
        with self.assertRaisesRegex(manifest.AdapterError, 'Help link'):
            check('fixture', 'example.cnx', original, excerpt.replace('|example|', '|missing|'), {'section'})


if __name__ == '__main__':
    unittest.main()
