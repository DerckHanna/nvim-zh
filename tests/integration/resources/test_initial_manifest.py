import shutil
import subprocess
from process_case import TempNeovimCase, ROOT, NVIM


class ResourceTests(TempNeovimCase):
    def test_invalid_initial_manifest_does_not_break_query_or_enable_unverified_data(self):
        source = self.base / 'source'
        for name in ('lua', 'plugin'):
            shutil.copytree(ROOT / name, source / name)
        (source / 'resources').mkdir()
        (source / 'resources/manifest.json').write_text('[]')
        self.env['NVIM_ZH_INVALID_ROOT'] = str(source)
        script = self.script(r'''
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_INVALID_ROOT)
local z=require('nvim-zh')
assert(not z.status().configured)
z.setup({modules={core={enabled=false}}})
assert(z.status().runtime.status=='error','bad manifest marked success')
assert(z.translate({domain='nvim-ui',msgid='No information available'})=='No information available','unverified builtin data was used')
assert(z.status().version.active_bundle==nil)
print('INVALID_INITIAL_MANIFEST=PASS')
''')
        process = subprocess.run([NVIM, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', str(script)],
                                 env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn('INVALID_INITIAL_MANIFEST=PASS', process.stdout + process.stderr)


if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
