import json
import shutil
import sys
from process_case import TempNeovimCase, ROOT


class ResourceTests(TempNeovimCase):
    def test_po_build_and_release_version_do_not_require_code_restart(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import resource_bundle as bundle
        import catalog_tool
        source = self.base / 'source'
        for name in ('lua', 'plugin', 'translations', 'manifests', 'doc'):
            shutil.copytree(ROOT / name, source / name)
        shutil.copyfile(ROOT / 'VERSION', source / 'VERSION')
        mo_file = 'build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
        (source / mo_file).parent.mkdir(parents=True)
        shutil.copyfile(ROOT / mo_file, source / mo_file)
        before = json.loads(bundle.contents(source)['manifest.json'])
        po = source / 'translations/po/zh_CN/nvim-ui.po'
        original = po.read_text()
        self.assertIn('msgstr "没有可用的信息"', original)
        po.write_text(original.replace('msgstr "没有可用的信息"', 'msgstr "暂时没有可用的信息"'))
        catalog_tool.build(source / 'translations/po/zh_CN', source / 'lua/nvim-zh/catalogs/generated',
                           source / 'translations/glossary/zh_CN.toml')
        after = json.loads(bundle.contents(source)['manifest.json'])
        self.assertEqual(before['implementation']['id'], after['implementation']['id'])
        self.assertNotEqual(before['bundle']['id'], after['bundle']['id'])
        (source / 'VERSION').write_text('0.1.1-dev\n')
        release = json.loads(bundle.contents(source)['manifest.json'])
        self.assertEqual(after['implementation']['id'], release['implementation']['id'])
        code = source / 'lua/nvim-zh/ui.lua'
        code.write_text(code.read_text() + '\n-- implementation change\n')
        changed = json.loads(bundle.contents(source)['manifest.json'])
        self.assertNotEqual(release['implementation']['id'], changed['implementation']['id'])


if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
