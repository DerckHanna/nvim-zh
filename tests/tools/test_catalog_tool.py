import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
sys.path.insert(0, str(ROOT / 'tools'))
import catalog_tool  # noqa: E402


VALID_PO = r'''msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"
"X-Generator: nvim-zh-tests\n"

#: lua/demo.lua:10 lua/other.lua:2
msgctxt "menu"
msgid "Open"
msgstr "打开"

#: lua/demo.lua:20
msgid "File {name}"
msgstr "文件 {name}"

msgid "Cannot open %s: %s"
msgstr "无法打开 %s：%s"

msgid "Literal 100% [ok]"
msgstr "字面量 100% [好]"
'''

GLOSSARY = '''[[term]]
source = "Buffer"
policy = "preserve"
forbidden = ["缓冲区"]

[[term]]
source = "Window"
policy = "preserve"
forbidden = ["窗口"]

[[term]]
source = "Register"
policy = "preserve"
forbidden = ["寄存器"]
'''


class CatalogToolTests(unittest.TestCase):
    def setUp(self):
        stamp = time.strftime('%Y%m%d-%H%M%S')
        self.tmp = tempfile.TemporaryDirectory(prefix=f'dsh-nvim-zh-tools-{stamp}-')
        self.root = Path(self.tmp.name)
        self.po_dir = self.root / 'po'
        self.po_dir.mkdir()
        self.output = self.root / 'generated'
        self.glossary = self.root / 'glossary.toml'
        self.glossary.write_text(GLOSSARY, encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def write_po(self, text=VALID_PO, name='demo.po'):
        path = self.po_dir / name
        path.write_text(text, encoding='utf-8')
        return path

    def test_build_is_reproducible_and_preserves_metadata(self):
        self.write_po()
        first = catalog_tool.build(self.po_dir, self.output, self.glossary)
        snapshot = {path.name: path.read_bytes() for path in first}
        second = catalog_tool.build(self.po_dir, self.output, self.glossary)
        self.assertEqual(snapshot, {path.name: path.read_bytes() for path in second})
        generated = snapshot['demo.lua'].decode('utf-8')
        self.assertIn('domain = "demo"', generated)
        self.assertIn('context = "menu"', generated)
        self.assertIn('lua/demo.lua:10', generated)
        self.assertIn('["X-Generator"] = "nvim-zh-tests"', generated)
        self.assertLess(generated.index('msgid = "Cannot open'), generated.index('msgid = "File {name}"'))

    def test_duplicate_context_key_and_malformed_po_are_rejected(self):
        duplicate = VALID_PO + '\nmsgctxt "menu"\nmsgid "Open"\nmsgstr "重复"\n'
        self.write_po(duplicate)
        with self.assertRaisesRegex(catalog_tool.CatalogError, 'duplicate'):
            catalog_tool.check(self.po_dir, self.glossary)
        self.write_po('msgid "unterminated\nmsgstr "值"\n')
        with self.assertRaisesRegex(catalog_tool.CatalogError, 'PO'):
            catalog_tool.check(self.po_dir, self.glossary)

    def test_placeholder_mismatch_reordering_and_empty_translation_are_rejected(self):
        cases = [
            'msgid "Value %s"\nmsgstr "值 %d"\n',
            'msgid "%s then %d"\nmsgstr "%d 然后 %s"\n',
            'msgid "File {name}"\nmsgstr "文件 {path}"\n',
            'msgid "Empty"\nmsgstr ""\n',
            'msgid "Bad %*s"\nmsgstr "错误 %*s"\n',
        ]
        for source in cases:
            with self.subTest(source=source):
                self.write_po(source)
                with self.assertRaises(catalog_tool.CatalogError):
                    catalog_tool.check(self.po_dir, self.glossary)

    def test_preserved_terms_and_protected_spans_are_enforced(self):
        cases = [
            'msgid "Close Buffer"\nmsgstr "关闭缓冲区"\n',
            'msgid "Close Window"\nmsgstr "关闭窗口"\n',
            'msgid "Clear Register"\nmsgstr "清除寄存器"\n',
            'msgid "Buffers"\nmsgstr "缓冲区"\n',
            'msgid "current buffer"\nmsgstr "当前缓冲区"\n',
            'msgid "Switch windows"\nmsgstr "切换窗口"\n',
            'msgid "registers"\nmsgstr "寄存器"\n',
            'msgid "Run :NvimZhCheck"\nmsgstr "运行 :NvimZhInfo"\n',
            'msgid "Press <C-x>"\nmsgstr "按 <C-q>"\n',
            'msgid "Call vim.api.nvim_buf_get_lines()"\nmsgstr "调用 vim.api.nvim_buf_del_lines()"\n',
            'msgid "Set `textwidth`"\nmsgstr "设置 `宽度`"\n',
            'msgid "Read /tmp/input.lua"\nmsgstr "读取 /tmp/output.lua"\n',
            'msgid "Set buffer_name"\nmsgstr "设置 buffer_id"\n',
        ]
        for source in cases:
            with self.subTest(source=source):
                self.write_po(source)
                with self.assertRaises(catalog_tool.CatalogError):
                    catalog_tool.check(self.po_dir, self.glossary)

    def test_valid_terms_unicode_newlines_and_literal_percent_are_accepted(self):
        source = r'''msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "Close Buffer with :NvimZhCheck"
msgstr "使用 :NvimZhCheck 关闭 Buffer"

msgid "Line one\nLine two 你好"
msgstr "第一行\n第二行 你好"

msgid "Progress 100%"
msgstr "进度 100%"

msgid "Buffers and current buffer"
msgstr "Buffer"

msgid "Switch windows and registers"
msgstr "切换 Window 和 Register"
'''
        self.write_po(source)
        result = catalog_tool.check(self.po_dir, self.glossary)
        self.assertEqual(result['entries'], 5)
        self.assertEqual(result['translated'], 5)

    def test_production_sources_are_derived_from_catalog_and_reject_drift(self):
        import shutil
        source = self.root / 'source'
        (source / 'lua/nvim-zh').mkdir(parents=True)
        shutil.copyfile(ROOT / 'lua/nvim-zh/catalog.lua', source / 'lua/nvim-zh/catalog.lua')
        shutil.copytree(ROOT / 'translations/po', source / 'translations/po')
        actual = catalog_tool.builtin_sources(source)
        self.assertEqual(set(actual), {'nvim-ui', 'which-key', 'telescope', 'nvim-tree', 'clangd'})
        extra = source / 'translations/po/zh_CN/unregistered.po'
        extra.write_text(VALID_PO)
        with self.assertRaisesRegex(catalog_tool.CatalogError, 'differ'):
            catalog_tool.builtin_sources(source)
        extra.unlink()
        (source / 'translations/po/zh_CN/which-key.po').unlink()
        with self.assertRaisesRegex(catalog_tool.CatalogError, 'differ'):
            catalog_tool.builtin_sources(source)

    def test_invalid_utf8_is_rejected(self):
        path = self.po_dir / 'demo.po'
        path.write_bytes(b'msgid "text"\nmsgstr "\xff"\n')
        with self.assertRaisesRegex(catalog_tool.CatalogError, 'UTF-8'):
            catalog_tool.check(self.po_dir, self.glossary)


if __name__ == '__main__':
    unittest.main()
