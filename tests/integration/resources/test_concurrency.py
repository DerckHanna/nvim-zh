import json
import subprocess
import time
from process_case import TempNeovimCase, ROOT, NVIM


class ResourceTests(TempNeovimCase):
    def test_concurrent_sessions_publish_same_snapshot(self):
        self.env['NVIM_ZH_BARRIER'] = str(self.base / 'go')
        script = self.script(r'''
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_ROOT)
local marker=vim.env.NVIM_ZH_BARRIER
vim.fn.writefile({'ready'},marker .. '.' .. vim.uv.os_getpid())
assert(vim.wait(10000,function() return vim.fn.filereadable(marker)==1 end,10))
local zh=require('nvim-zh')
zh.setup({modules={core={enabled=false}}})
assert(zh.status().runtime.status=='ok',vim.inspect(zh.status().runtime))
local id=assert(zh.status().version.active_bundle)
vim.fn.writefile({id},marker .. '.bundle.' .. vim.uv.os_getpid())
print('CONCURRENT_SNAPSHOT=PASS')
''')
        processes = [subprocess.Popen([NVIM, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', str(script)],
                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
        try:
            deadline = time.monotonic() + 10
            while len(list(self.base.glob('go.*'))) < 2 and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertEqual(len(list(self.base.glob('go.*'))), 2)
            (self.base / 'go').write_text('go')
            for process in processes:
                stdout, stderr = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 0, stdout + stderr)
                self.assertIn('CONCURRENT_SNAPSHOT=PASS', stdout + stderr)
            bundles = [p.read_text().strip() for p in self.base.glob('go.bundle.*')]
            self.assertEqual(len(bundles), 2)
            self.assertEqual(bundles[0], bundles[1], 'processes activated different bundles')
            disk = json.loads((self.base / 'data/nvim/nvim-zh/state.json').read_text())
            self.assertEqual(disk['active'], bundles[0], 'final disk generation differs from active processes')
            installed = json.loads((ROOT / 'resources/manifest.json').read_text())['bundle']['id']
            self.assertEqual(disk['active'], installed)
            snapshot = self.base / 'data/nvim/nvim-zh/resources' / disk['active']
            self.assertEqual(json.loads((snapshot / 'manifest.json').read_text())['bundle']['id'], disk['active'])
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill(); process.communicate()


if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
