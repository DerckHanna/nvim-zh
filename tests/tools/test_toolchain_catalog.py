import tempfile
import unittest
from pathlib import Path

import catalog_tool
import diagnostic_inventory
import toolchain_catalog


class ToolchainCatalogTests(unittest.TestCase):
    def test_bilingual_expansion_uses_source_branch_choices(self):
        source = "%select{zero|one}0/%sub{label}1/%diff{$ vs $|plain}0,1"
        target = "%select{零|一}0/%sub{label}1/%diff{$ 对 $|普通}0,1"
        source_subs = {"label": "%plural{1:item|:items}0"}
        target_subs = {"label": "%plural{1:件|:多件}0"}
        expanded = diagnostic_inventory.expand_template(source, source_subs, track_choices=True)
        self.assertEqual(diagnostic_inventory.normalize_template(source, source_subs),
                         [text for text, _ in expanded])
        self.assertEqual(len(expanded), 8)
        pairs = {
            text: diagnostic_inventory.expand_template(target, target_subs, selected=choices)[0][0]
            for text, choices in expanded
        }
        self.assertEqual(pairs["zero/item/%0 vs %1"], "零/件/%0 对 %1")
        self.assertEqual(pairs["one/items/plain"], "一/多件/普通")

    def test_generate_and_check_in_empty_output_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            self.assertEqual(toolchain_catalog.main(["sync", "--output", directory]), 0)
            root = toolchain_catalog.ROOT / "translations/po/zh_CN"
            for domain in ("clang", "clangd", "clang-tidy"):
                self.assertEqual((output / f"{domain}.po").read_bytes(), (root / f"{domain}.po").read_bytes())
            path = output / "clangd.po"
            rendered = path.read_text(encoding="utf-8")
            path.write_text(rendered.replace('msgstr "取消"', 'msgstr "放弃"', 1), encoding="utf-8")
            with self.assertRaisesRegex(catalog_tool.CatalogError, "stale"):
                toolchain_catalog.verify_po(path, rendered)


if __name__ == "__main__":
    unittest.main(verbosity=2)
