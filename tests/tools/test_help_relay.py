import hashlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
sys.path.insert(0, str(ROOT / 'tools'))
import help_relay as relay  # noqa: E402


class HelpRelayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nvim-zh-help-relay-')
        self.root = Path(self.tmp.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir()
        (self.root / 'manifests').mkdir()
        (self.root / 'doc').mkdir()
        self.old_root = relay.ROOT
        self.old_runtime = relay.RUNTIME_DOC
        relay.ROOT = self.root
        relay.RUNTIME_DOC = self.runtime
        self.source = self.runtime / 'sample.txt'
        self.target = self.root / 'doc' / 'sample.cnx'
        self.set_upstream('*sample.txt*\n')

    def tearDown(self):
        relay.ROOT = self.old_root
        relay.RUNTIME_DOC = self.old_runtime
        self.tmp.cleanup()

    def set_upstream(self, text):
        self.source.write_text(text, encoding='utf-8')
        digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        manifest = {'upstreams': {'neovim': {'documents': {
            'sample.txt': {'sha256': digest},
        }}}}
        (self.root / 'manifests' / 'upstreams.json').write_text(
            json.dumps(manifest), encoding='utf-8')

    def capture(self, function, *args, **kwargs):
        output = io.StringIO()
        with redirect_stdout(output):
            result = function(*args, **kwargs)
        return result, output.getvalue()

    def test_registered_basename_and_hash_are_accepted(self):
        text = '*sample.txt*\nlegal |sample-link|\n'
        self.set_upstream(text)
        self.assertEqual(relay.upstream_text('sample.txt'), text)
        self.assertEqual(relay.pinned_sha256('sample.txt'),
                         hashlib.sha256(text.encode()).hexdigest())
        self.assertEqual(relay.target('sample.txt'), self.target)

    def test_names_must_be_registered_exact_basenames(self):
        escaped = self.root / 'escaped.txt'
        escaped.write_text('escaped\n', encoding='utf-8')
        # Make this old-implementation escape readable as ../escaped.txt.
        for name in ('/etc/passwd', '../escaped.txt', 'doc/sample.txt', 'missing.txt'):
            with self.subTest(name=name):
                with self.assertRaises(SystemExit):
                    relay.upstream_text(name)

    def test_cli_does_not_turn_shorthand_into_a_registered_name(self):
        with self.assertRaises(SystemExit):
            relay.main(['plan', 'sample', '--runtime', str(self.runtime)])

    def test_missing_pinned_hash_fails_closed(self):
        manifest_path = self.root / 'manifests' / 'upstreams.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        del manifest['upstreams']['neovim']['documents']['sample.txt']['sha256']
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        with self.assertRaisesRegex(SystemExit, 'sha256'):
            relay.upstream_text('sample.txt')

    def test_hash_mismatch_is_rejected(self):
        self.source.write_text('tampered\n', encoding='utf-8')
        with self.assertRaisesRegex(SystemExit, 'differs from the pinned manifest'):
            relay.upstream_text('sample.txt')

    def test_source_symlink_is_rejected(self):
        text = '*sample.txt*\n'
        outside = self.root / 'outside.txt'
        outside.write_text(text, encoding='utf-8')
        self.source.unlink()
        self.source.symlink_to(outside)
        with self.assertRaisesRegex(SystemExit, 'symlink'):
            relay.upstream_text('sample.txt')

    def test_target_symlinks_are_rejected(self):
        outside = self.root / 'outside.cnx'
        outside.write_text('do not touch\n', encoding='utf-8')
        for path in (self.target, self.target.with_name(self.target.name + '.partial')):
            with self.subTest(path=path.name):
                path.symlink_to(outside)
                with self.assertRaisesRegex(SystemExit, 'symlink'):
                    relay.target('sample.txt')
                path.unlink()

    def test_ready_requires_the_exact_link_multiset(self):
        upstream = '*sample.txt*\n|one| |two|\nExample >\n  body\nEnd\n'
        self.set_upstream(upstream)
        text = relay.skeleton(upstream).replace(' |two|', '')
        state, problems, _ = relay._gate(text, upstream)
        self.assertEqual(state, 'FAIL')
        self.assertTrue(any('link' in problem for problem in problems), problems)

    def test_complete_requires_the_exact_link_multiset(self):
        upstream = '*sample.txt*\n|one| |two|\n'
        text = upstream.replace(' |two|', '')
        state, problems, _ = relay._gate(text, upstream)
        self.assertEqual(state, 'FAIL')
        self.assertTrue(any('link' in problem for problem in problems), problems)

    def test_gate_rejects_non_standalone_placeholder(self):
        upstream = '>\n  body\nEnd\n'
        text = '>\ninline @@BLOCK@@\nEnd\n'
        state, problems, _ = relay._gate(text, upstream)
        self.assertEqual(state, 'FAIL')
        self.assertTrue(any('placeholder' in problem for problem in problems), problems)

    def test_check_segment_rejects_misplaced_placeholder(self):
        self.set_upstream('>\n  body\nEnd\n')
        segment = self.root / 'bad.seg'
        segment.write_text('@@BLOCK@@\n>\nEnd\n', encoding='utf-8')
        result, output = self.capture(
            relay.check_segment, 'sample.txt', 1, 3, str(segment))
        self.assertEqual(result, 1, output)
        self.assertIn('SEGMENT_CHECK=FAIL', output)
        self.assertIn('placeholder', output)

    def test_check_segment_accepts_legal_block_boundaries(self):
        # The first placeholder is terminated by the next fence; the last is at
        # segment EOF. Both are legal skeleton boundaries and must not be hurt
        # by the stricter pairing/terminator checks.
        upstream = '>\n  one\n>\n  two\n'
        self.set_upstream(upstream)
        segment = self.root / 'good.seg'
        segment.write_text(relay.skeleton(upstream), encoding='utf-8')
        result, output = self.capture(
            relay.check_segment, 'sample.txt', 1, 4, str(segment))
        self.assertEqual(result, 0, output)
        self.assertIn('SEGMENT_CHECK=PASS', output)

    def test_assemble_fail_leaves_bytes_and_mode_untouched(self):
        upstream = '*sample.txt*\nIntro |one|\nExample >\n  body\nEnd\n'
        self.set_upstream(upstream)
        original = relay.skeleton(upstream).replace('*sample.txt*\n', '')
        self.target.write_text(original, encoding='utf-8')
        self.target.chmod(0o600)
        result, output = self.capture(relay.assemble, 'sample.txt')
        self.assertEqual(result, 1, output)
        self.assertIn('RELAY_ASSEMBLE=FAIL', output)
        self.assertEqual(self.target.read_text(encoding='utf-8'), original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)

    def test_assemble_validation_exception_leaves_file_untouched(self):
        upstream = '*sample.txt*\nIntro |one|\nExample >\n  body\nEnd\n'
        self.set_upstream(upstream)
        original = relay.skeleton(upstream)
        self.target.write_text(original, encoding='utf-8')
        self.target.chmod(0o600)
        with mock.patch.object(relay.parity, 'example_blocks',
                               side_effect=RuntimeError('validation exploded')):
            with self.assertRaisesRegex(RuntimeError, 'validation exploded'):
                relay.assemble('sample.txt')
        self.assertEqual(self.target.read_text(encoding='utf-8'), original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)

    def test_assemble_replace_exception_leaves_file_untouched(self):
        upstream = '*sample.txt*\nIntro |one|\nExample >\n  body\nEnd\n'
        self.set_upstream(upstream)
        original = relay.skeleton(upstream)
        self.target.write_text(original, encoding='utf-8')
        self.target.chmod(0o600)
        with mock.patch.object(relay.os, 'replace', side_effect=OSError('replace failed')):
            with self.assertRaisesRegex(OSError, 'replace failed'):
                relay.assemble('sample.txt')
        self.assertEqual(self.target.read_text(encoding='utf-8'), original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)

    def test_assemble_success_uses_real_injection_and_contract(self):
        upstream = '*sample.txt*\nIntro |one|\nExample >\n  body\nEnd\n'
        self.set_upstream(upstream)
        self.target.write_text(relay.skeleton(upstream), encoding='utf-8')
        self.target.chmod(0o600)
        result, output = self.capture(relay.assemble, 'sample.txt')
        self.assertEqual(result, 0, output)
        self.assertIn('RELAY_ASSEMBLE=PASS', output)
        self.assertEqual(self.target.read_text(encoding='utf-8'), upstream)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o644)

    def test_plan_last_line_cut_does_not_read_past_inside(self):
        self.set_upstream('a\nb\nc\n\n')
        rows = relay.plan('sample.txt', 3)
        self.assertEqual([(row['from'], row['to']) for row in rows], [(1, 3), (4, 4)])
        self.assertEqual(sum(row['lines'] for row in rows), 4)

    def test_plan_rejects_invalid_target_lines(self):
        for value in (0, -1):
            with self.subTest(target_lines=value):
                with self.assertRaisesRegex(ValueError, 'target_lines'):
                    relay.plan('sample.txt', value)

    def test_unsplittable_plan_is_explicit_and_compatible(self):
        self.set_upstream(''.join(f'line {i}\n' for i in range(20)))
        rows = relay.plan('sample.txt', 5)
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['unsplittable'])
        self.assertTrue(rows[0]['oversized'])
        self.assertIn('no safe cut', rows[0]['warning'])
        result, output = self.capture(
            relay.main, ['plan', 'sample.txt', '--lines', '5',
                         '--runtime', str(self.runtime)])
        self.assertEqual(result, 0, output)
        self.assertIn('RELAY_WARNING=unsplittable', output)
        self.assertIn('oversized=1 unsplittable=1', output)

    def test_verify_rejects_invalid_upto_even_for_complete_file(self):
        upstream = '*sample.txt*\n|one|\n'
        self.set_upstream(upstream)
        self.target.write_text(upstream, encoding='utf-8')
        for value in (0, -1, 2):
            with self.subTest(upto=value):
                result, output = self.capture(relay.verify, 'sample.txt', value, 300)
                self.assertEqual(result, 1, output)
                self.assertIn('--upto', output)
                self.assertIn('RELAY_VERIFY=FAIL', output)

    def test_verify_rejects_invalid_target_lines(self):
        upstream = '*sample.txt*\n'
        self.set_upstream(upstream)
        self.target.write_text(upstream, encoding='utf-8')
        result, output = self.capture(relay.verify, 'sample.txt', None, 0)
        self.assertEqual(result, 1, output)
        self.assertIn('target_lines', output)
        self.assertIn('RELAY_VERIFY=FAIL', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
