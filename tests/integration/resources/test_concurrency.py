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


    def test_concurrent_pack_generation_has_one_winner(self):
        self.env['NVIM_ZH_BARRIER'] = str(self.base / 'packs-go')
        script = self.script(r"""
vim.opt.runtimepath:prepend(vim.env.NVIM_ZH_ROOT)
local marker = vim.env.NVIM_ZH_BARRIER
local store = require('nvim-zh.pack_store')
local expected = store.record('race').generation
assert(expected == 0)
local version = vim.env.NVIM_ZH_TEST_PACK_VERSION
local catalog = vim.json.encode({ schema = 1, domain = 'race', locale = 'zh_CN',
  entries = { { msgid = 'Ready', msgstr = version } } })
local path = 'catalogs/zh_CN.json'
local manifest = { schema = 1, sdk = 1, id = 'race', domain = 'race', locale = 'zh_CN', version = version,
  files = { [path] = { size = #catalog, sha256 = vim.fn.sha256(catalog) } } }
local _, digest = store.stage(vim.json.encode({ manifest = manifest, files = { [path] = catalog } }))
vim.fn.writefile({ 'ready' }, marker .. '.' .. version)
assert(vim.wait(10000, function() return vim.fn.filereadable(marker) == 1 end, 10))
local selected = { version = version, sha256 = digest, source = 'local', allow_lua = false }
local won, err = pcall(store.commit, 'race', expected, { selected = selected })
assert(won or tostring(err):find('包登记已变更', 1, true), err)
local record = store.record('race')
assert(record.generation == expected + 1)
local candidate = store.load('race', record.selected)
assert(candidate.catalog.entries[1].msgstr == record.selected.version)
assert(not won or record.selected.sha256 == digest)
vim.fn.writefile({ vim.json.encode({ won = won, generation = record.generation, selected = record.selected }) },
  marker .. '.result.' .. version)
""")
        processes = [subprocess.Popen(
            [NVIM, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', str(script)],
            env=dict(self.env, NVIM_ZH_TEST_PACK_VERSION=version),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for version in ('1.0.0', '1.0.1')]
        try:
            deadline = time.monotonic() + 10
            while len(list(self.base.glob('packs-go.1.*'))) < 2 and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertEqual(len(list(self.base.glob('packs-go.1.*'))), 2)
            (self.base / 'packs-go').write_text('go')
            for process in processes:
                stdout, stderr = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 0, stdout + stderr)
            results = [json.loads(path.read_text()) for path in self.base.glob('packs-go.result.*')]
            self.assertEqual(len(results), 2)
            self.assertEqual(sum(result['won'] for result in results), 1)
            self.assertEqual(results[0]['selected'], results[1]['selected'])
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
