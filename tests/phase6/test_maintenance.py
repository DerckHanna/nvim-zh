import json
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


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        stamp = time.strftime('%Y%m%d-%H%M%S')
        self.tmp = tempfile.TemporaryDirectory(prefix=f'dsh-nvim-zh-phase6-{stamp}-', dir='/tmp')
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_sync_reports_source_and_catalog_changes(self):
        fixture = json.loads((ROOT / 'tests/phase6/fixtures/sync-change.json').read_text(encoding='utf-8'))
        before, after = fixture['before'], fixture['after']
        report = catalog_tool.compare_sync(before, after)
        kinds = {item['kind'] for item in report}
        self.assertIn('source_changed', kinds)
        self.assertIn('source_added', kinds)
        self.assertIn('entry_added', kinds)
        self.assertIn('entry_removed', kinds)
        self.assertIn('untranslated', kinds)
        self.assertTrue(any(item['kind'] == 'msgid_changed' and item['msgid'] == 'Open' for item in report))

    def test_release_check_rejects_dirty_package(self):
        (self.root / 'lua').mkdir()
        (self.root / 'lua' / 'ok.lua').write_text('return {}\n', encoding='utf-8')
        (self.root / 'zero.tmp').write_bytes(b'')
        (self.root / 'debug.log').write_text('log', encoding='utf-8')
        (self.root / '__pycache__').mkdir()
        (self.root / '__pycache__' / 'x.pyc').write_bytes(b'x')
        problems = catalog_tool.release_check(self.root)
        self.assertGreaterEqual(len(problems), 4)

    def test_release_check_rejects_neovim_fallback_log(self):
        # Neovim writes ./nvim.log when its state directory is read-only, which
        # is exactly the sandbox condition that used to pollute the package.
        (self.root / 'nvim.log').write_text('WRN server_start\n', encoding='utf-8')
        problems = catalog_tool.release_check(self.root)
        self.assertTrue(any('nvim.log' in problem for problem in problems), problems)

    def test_release_check_rejects_dot_nvimlog(self):
        # 0.10/0.11 fall back to ./.nvimlog instead. Its path suffix is empty
        # (leading dot), so the suffix rule alone would let it ship.
        (self.root / '.nvimlog').write_text('WRN server_start\n', encoding='utf-8')
        problems = catalog_tool.release_check(self.root)
        self.assertTrue(any('.nvimlog' in problem for problem in problems), problems)

    def test_phase_entry_points_isolate_neovim_state(self):
        # Entry points only: tests/phase0/e1_native.sh is invoked *by* a guarded
        # run.sh and inherits its XDG_STATE_HOME, so it is not a leak source on
        # its own. The original guard globbed only phase*/run.sh and therefore
        # never inspected tests/phase7/foundation.sh, which leaked nvim.log /
        # .nvimlog into the repository root on every one of 0.12.6, 0.11.5 and
        # 0.10.4. Assert the foundation entry point is covered before checking.
        runners = sorted(ROOT.joinpath("tests").glob("phase*/run.sh"))
        runners += sorted(ROOT.joinpath("tests").glob("phase*/foundation.sh"))
        self.assertIn(ROOT / "tests/phase7/foundation.sh", runners,
                      'the foundation entry point must be covered by this guard')
        for runner in runners:
            text = runner.read_text(encoding='utf-8')
            # Whole-token, not substring: "XDG_STATE_HOME_UNUSED=$state" still
            # contains the token and used to satisfy a plain assertIn() while the
            # guard was effectively disabled.
            self.assertRegex(text, r'(?m)^\s*export XDG_STATE_HOME=',
                             f'{runner} can leak nvim.log into the package')
            self.assertIn('trap', text, f'{runner} does not clean up its state dir')

    def test_release_check_accepts_clean_package(self):
        (self.root / 'lua').mkdir()
        (self.root / 'lua' / 'ok.lua').write_text('return {}\n', encoding='utf-8')
        (self.root / 'README.md').write_text('ok\n', encoding='utf-8')
        self.assertEqual(catalog_tool.release_check(self.root), [])

    def test_ci_matrix_and_offline_boundaries_are_declared(self):
        workflow = (ROOT / '.github/workflows/test.yml').read_text(encoding='utf-8')
        self.assertIn('v0.12.6', workflow)
        self.assertIn('experimental: false', workflow)
        self.assertIn('nightly', workflow)
        self.assertIn('v0.10.4', workflow)
        self.assertIn('scope: foundation', workflow)
        self.assertIn('upstream-smoke:', workflow)

    def test_phase8_runtime_comparisons_are_pinned_guarded(self):
        # A runtime that is not the pinned baseline may not ship a pinned
        # document or literal at all (0.11.5 lacks 10 documents, nightly dropped
        # pi_zip.txt), so upstream comparisons must be pinned-only while the
        # translation contract keeps running on every version.
        catalog = (ROOT / 'tests/phase8/01_help_catalog_spec.lua').read_text(encoding='utf-8')
        # The emitted marker, not just the bare word: a rename that keeps the
        # substring would otherwise satisfy a plain assertIn().
        self.assertIn("',upstream_absent'", catalog)
        marker = '\n  if pinned then\n'  # the real guard, not the phrase in a comment
        guarded = catalog[catalog.index(marker):catalog.index('local upstream =')]
        self.assertIn('check(upstream_present', guarded)
        lsp = (ROOT / 'tests/phase8/02_lsp_ui_text_spec.lua').read_text(encoding='utf-8')
        self.assertIn('if not pinned then return end', lsp)
        parity = (ROOT / 'tests/phase8/check_help_parity.py').read_text(encoding='utf-8')
        self.assertIn('HELP_PARITY=SKIP', parity)

    def test_phase8_translation_contract_runs_on_every_version(self):
        # The tag/example-block/link contract must be asserted *outside* the
        # pinned guard, from the digests in manifests/help_inventory.json:
        # otherwise deleting a tag or rewriting an example block passes on
        # 0.11.5/nightly while failing on 0.12.6.
        catalog = (ROOT / 'tests/phase8/01_help_catalog_spec.lua').read_text(encoding='utf-8')
        head = catalog[:catalog.index('\n  if pinned then\n')]
        self.assertIn('translation_contract', head,
                      'the translation contract must be asserted before the pinned guard')
        inventory_tool = (ROOT / 'tools/help_inventory.py').read_text(encoding='utf-8')
        # Match the emitted keyword, so 'tags_digest_RENAMED' cannot satisfy it.
        for field in ('tags_digest', 'blocks_digest', 'links_digest', 'tail_digest'):
            self.assertIn(f"'{field}':", inventory_tool,
                          f'help_inventory.py must emit {field}')
        tags = (ROOT / 'tests/phase8/test_help_catalog.py').read_text(encoding='utf-8')
        for name in ('def test_shipped_tags_are_internally_consistent(',
                     'def test_helptags_regeneration_is_not_destructive(',
                     'def test_first_lines_share_one_encoding_class('):
            self.assertIn(name, tags, f'{name} must exist: it is the cross-version tags guard')

    def test_cross_version_classification_and_index_gates_are_wired_in(self):
        # The runtime-classification and index-pattern rules are what catch an
        # off-pin regression, so assert they are still present and still applied
        # to every file they own (a silent removal turns them into no-ops).
        rules = (ROOT / 'tests/phase8/03_help_parity_rules_spec.lua').read_text(encoding='utf-8')
        # Trailing comma: a rename to 'doc/tags-cn-DISABLED' kept the substring.
        self.assertIn("check_tags_file('doc/tags-cn',", rules,
                      'doc/tags-cn patterns must be checked on every version')
        self.assertIn("check_tags_file('doc/tags',", rules,
                      'doc/tags patterns must be checked on every version, not only when pinned')
        for name in ('tests/phase1/04_docs_spec.lua',
                     'tests/phase8/01_help_catalog_spec.lua',
                     'tests/phase8/02_lsp_ui_text_spec.lua'):
            text = (ROOT / name).read_text(encoding='utf-8')
            self.assertIn('pinned/unpinned cannot be decided', text,
                          f'{name} lost the prerelease pinned-version gate')
        checker = (ROOT / 'tests/phase8/check_help_parity.py').read_text(encoding='utf-8')
        self.assertIn('def probe_documents(', checker)
        # Behavioural, not textual: a string match on "def probe_documents" also
        # matches "def probe_documents_renamed", so call the real function.
        sys.path.insert(0, str(ROOT / 'tests' / 'phase8'))
        import check_help_parity  # noqa: E402
        probes = check_help_parity.probe_documents(['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt'])
        self.assertGreater(len(probes), 1, 'the pinned baseline must not rest on one document')
        self.assertEqual(check_help_parity.probe_documents([]), [])
        skip = (ROOT / 'tests/phase8/test_help_parity_skip.py').read_text(encoding='utf-8')
        for name in ('def test_pinned_runtime_with_wrong_content_is_rejected',
                     'def test_prerelease_build_claiming_the_pinned_version_is_a_hard_error'):
            self.assertIn(name, skip, f'{name} must exist: it pins the classification gate')

    def test_help_inventory_class_is_not_wholly_pinned_only(self):
        # 6 of the 7 inventory tests only compare repository JSON files; only
        # the two that read $VIMRUNTIME may skip on a non-pinned runtime.
        inventory = (ROOT / 'tests/phase8/test_help_inventory.py').read_text(encoding='utf-8')
        preceding = inventory[:inventory.index('class HelpInventoryTests')].rstrip().splitlines()
        self.assertFalse(preceding[-1].lstrip().startswith('@'),
                         'HelpInventoryTests must not carry a class-level skipUnless')
        for name in ('def test_inventory_regenerates_byte_identically',
                     'def test_inventory_covers_every_runtime_document_exactly_once',
                     'def test_translation_contracts_match_the_shipped_translations'):
            self.assertIn(name, inventory)
        self.assertIn('def test_translation_contracts_match_the_shipped_translations(',
                      inventory,
                      'the runtime-independent contract cross-check must exist')

    def test_current_manifest_has_full_commits_and_hashes(self):
        manifest = json.loads((ROOT / 'manifests/upstreams.json').read_text(encoding='utf-8'))
        for name, upstream in manifest['upstreams'].items():
            self.assertRegex(upstream['commit'], r'^[0-9a-f]{40}$', name)
            if name != 'neovim':
                self.assertTrue(upstream.get('sources'), name)
                for source, meta in upstream['sources'].items():
                    self.assertRegex(meta['sha256'], r'^[0-9a-f]{64}$', f'{name}:{source}')


if __name__ == '__main__':
    unittest.main()
