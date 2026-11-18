"""Keep manifests/help_inventory.json a truthful, complete per-document status.

The help corpus is "done" only when every `$VIMRUNTIME/doc/*.txt` has an explicit
status: complete, partial, deliberately excluded with evidence, or still
untranslated. This test makes the inventory auditable instead of a claim in a
report: it must regenerate byte-identically, cover the runtime exactly once,
agree with manifests/upstreams.json and manifests/help_exemptions.json, and -
without reading any runtime - reproduce every stored tag/example-block/link/
footer digest from the shipped translation.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
TOOL = ROOT / 'tools' / 'help_inventory.py'
INVENTORY = ROOT / 'manifests' / 'help_inventory.json'
MANIFEST = ROOT / 'manifests' / 'upstreams.json'
EXEMPTIONS = ROOT / 'manifests' / 'help_exemptions.json'
NVIM = os.environ.get('NVIM_BIN', 'nvim')
STATUSES = {'complete', 'partial', 'not_started', 'excluded'}
PINNED_ONLY = 'help inventory regeneration is pinned to the Neovim that generated it'
CONTRACT_KEYS = {'tag_count', 'block_count', 'link_count',
                 'tags_digest', 'blocks_digest', 'links_digest', 'tail_digest'}


def _pinned() -> bool:
    out = subprocess.run([NVIM, '--headless', '-u', 'NONE', '-c', 'lua io.write(vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)', '-c', 'qa!'],
                         capture_output=True, text=True, timeout=60,
                         env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', tempfile.gettempdir())})
    if out.returncode != 0:
        raise RuntimeError(f'Neovim version probe exited {out.returncode}: {out.stderr.strip()}')
    version = out.stdout.strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise RuntimeError(f'Neovim version probe returned unrecognised output: {version!r}')
    return version == '0.12.6'


def _runtime() -> Path:
    value = os.environ.get('VIMRUNTIME')
    if value and (Path(value) / 'doc').is_dir():
        return Path(value)
    out = subprocess.run([NVIM, '--headless', '-u', 'NONE', '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
                         capture_output=True, text=True, timeout=60,
                         env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', tempfile.gettempdir())})
    if out.returncode != 0:
        raise RuntimeError(f'VIMRUNTIME probe exited {out.returncode}: {out.stderr.strip()}')
    value = out.stdout.strip()
    if not value or not (Path(value) / 'doc').is_dir():
        raise RuntimeError(f'VIMRUNTIME probe returned an unusable path: {value!r}')
    return Path(value)


class HelpInventoryTests(unittest.TestCase):
    # Only the two tests that read $VIMRUNTIME are pinned-dependent: the
    # inventory is regenerated from the pinned corpus, and coverage is checked
    # against it. Every other test compares repository JSON files (and the
    # shipped doc/*.cnx) only, and must keep running on 0.11.5/nightly, where a
    # class-level decorator used to skip all of them silently (a desynchronised
    # inventory shipped unverified).
    @classmethod
    def setUpClass(cls) -> None:
        cls.inventory = json.loads(INVENTORY.read_text(encoding='utf-8'))
        cls.by_path = {item['path']: item for item in cls.inventory['documents']}

    @unittest.skipUnless(_pinned(), PINNED_ONLY)
    def test_inventory_regenerates_byte_identically(self) -> None:
        runtime = _runtime()
        result = subprocess.run(
            [sys.executable, str(TOOL), '--check'],
            capture_output=True, text=True, timeout=120, cwd=ROOT,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1',
                 'VIMRUNTIME': str(runtime),
                 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', tempfile.gettempdir())},
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    @unittest.skipUnless(_pinned(), PINNED_ONLY)
    def test_inventory_covers_every_runtime_document_exactly_once(self) -> None:
        runtime = _runtime()
        expected = {f'runtime/doc/{p.name}' for p in (runtime / 'doc').glob('*.txt')}
        self.assertEqual(set(self.by_path), expected)
        self.assertEqual(len(self.by_path), len(self.inventory['documents']))

    def test_every_status_is_explicit_and_counts_are_consistent(self) -> None:
        for path, item in self.by_path.items():
            self.assertIn(item['status'], STATUSES, path)
            self.assertIn(item['topic'], {'user-manual', 'filetype-plugin', 'packaged-plugin',
                                          'legacy-interface', 'developer', 'localization',
                                          'release-notes', 'api-reference', 'lua-reference',
                                          'reference'}, path)
            self.assertIn(item['priority'], (1, 2, 3), path)
        totals = self.inventory['totals']
        self.assertEqual(totals['documents'], len(self.by_path))
        for status in STATUSES:
            rows = [i for i in self.by_path.values() if i['status'] == status]
            self.assertEqual(totals[status], len(rows), status)
            self.assertEqual(totals[f'{status}_lines'], sum(r['lines'] for r in rows), status)
        self.assertEqual(totals['lines'], sum(i['lines'] for i in self.by_path.values()))

    def test_manifest_documents_agree_with_inventory(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
        declared = {Path(v['source']).name: v for v in manifest['upstreams']['neovim']['documents'].values()}
        self.assertTrue(declared, 'manifest declares no help documents')
        for name, meta in declared.items():
            item = self.by_path[f'runtime/doc/{name}']
            self.assertEqual(item['status'], meta['status'], name)
            self.assertEqual(item['translation'], meta['translation'], name)
            self.assertEqual(item['sha256'], meta['sha256'], name)
        for item in self.by_path.values():
            if Path(item['path']).name not in declared:
                self.assertIn(item['status'], {'not_started', 'excluded'}, item['path'])
                self.assertIsNone(item['translation'], item['path'])

    def test_translated_documents_carry_a_translation_contract(self) -> None:
        # The digests are what lets tests/contract/help assert the tag / example-block
        # / link contract on a runtime that never shipped the document. They are
        # derived from the pinned upstream, so a translated document must have
        # them and an untranslated one must not.
        for path, item in self.by_path.items():
            if item['status'] in ('complete', 'partial'):
                self.assertIsInstance(item['contract'], dict, path)
                self.assertEqual(set(item['contract']), CONTRACT_KEYS, path)
                self.assertRegex(item['contract']['tags_digest'], r'^[0-9a-f]{64}$', path)
                self.assertRegex(item['contract']['blocks_digest'], r'^[0-9a-f]{64}$', path)
                self.assertRegex(item['contract']['links_digest'], r'^[0-9a-f]{64}$', path)
                self.assertRegex(item['contract']['tail_digest'], r'^[0-9a-f]{64}$', path)
                self.assertGreater(item['contract']['tag_count'], 0, path)
            else:
                self.assertIsNone(item['contract'], path)

    def test_translation_contracts_match_the_shipped_translations(self) -> None:
        """The stored contract must equal what the shipped .cnx actually produces.

        No $VIMRUNTIME is read here, so this cross-check runs on *every* Neovim.
        Without it the only value-level verification lived in the two tests that
        skip off-pin, and a corrupted contract (or a drifted translation) shipped
        unverified on 0.11.5/nightly. It recomputes the digest with the same
        engine that generated it, so it cannot drift from the definition.
        """
        sys.path.insert(0, str(ROOT / 'tools'))
        import help_inventory  # noqa: E402
        checked = 0
        for path, item in sorted(self.by_path.items()):
            if item['status'] not in ('complete', 'partial'):
                continue
            text = (ROOT / item['translation']).read_text(encoding='utf-8')
            self.assertEqual(help_inventory.contract_fingerprint(text), item['contract'], path)
            checked += 1
        self.assertGreater(checked, 0, 'no translated document was cross-checked')

    def test_excluded_documents_carry_evidence(self) -> None:
        exemptions = json.loads(EXEMPTIONS.read_text(encoding='utf-8'))
        listed = {e['file'] for e in exemptions['exemptions']}
        excluded = {Path(i['path']).name for i in self.by_path.values() if i['status'] == 'excluded'}
        self.assertEqual(listed, excluded)
        for item in self.by_path.values():
            if item['status'] != 'excluded':
                self.assertIsNone(item['reason'], item['path'])
                self.assertIsNone(item['evidence'], item['path'])
                continue
            self.assertTrue(item['reason'], item['path'])
            self.assertTrue(item['evidence'], item['path'])

    def test_untranslated_help_is_reported_not_hidden(self) -> None:
        # Guards the project rule: normal user-facing help must never be parked
        # in "excluded" just to make the completion number look better. A
        # high-traffic reference (priority 1) or a user-manual tutorial
        # (priority 2) may never be excluded.
        for item in self.by_path.values():
            if item['status'] == 'excluded':
                self.assertEqual(item['priority'], 3, f'{item["path"]}: only low-traffic, '
                                                      'non-documentation pages may be excluded')
                self.assertNotIn(item['topic'], ('user-manual', 'api-reference', 'lua-reference'),
                                 item['path'])

    def test_totals_report_the_unfinished_remainder(self) -> None:
        totals = self.inventory['totals']
        unfinished = totals['partial'] + totals['not_started']
        self.assertEqual(unfinished + totals['complete'] + totals['excluded'], totals['documents'])
        # A completion claim must be visible in the data, not only in prose.
        self.assertEqual(totals['complete_lines'] + totals['partial_lines'] +
                         totals['not_started_lines'] + totals['excluded_lines'], totals['lines'])


if __name__ == '__main__':
    unittest.main(verbosity=1)
