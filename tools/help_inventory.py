#!/usr/bin/env python3
"""Deterministic per-document inventory of the pinned Neovim help corpus.

`manifests/upstreams.json` only records the documents that already ship a
translation. Completion of the whole help corpus also needs an explicit,
auditable status for *every* `$VIMRUNTIME/doc/*.txt`, including the ones that
are still untranslated and the few that are deliberately out of scope.

This tool derives that inventory from the pinned runtime plus the upstream
manifest, and writes `manifests/help_inventory.json`. It never edits help
documents, PO files or tags. Tag / example-block / link counting is delegated
to `tools/help_parity.py` so there is exactly one parity engine.

Usage:
    python3 tools/help_inventory.py            # regenerate (writes the file)
    python3 tools/help_inventory.py --check    # fail if the file is stale
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import help_parity as parity  # noqa: E402
from catalog_tool import atomic_write_text  # noqa: E402

MANIFEST = ROOT / 'manifests' / 'upstreams.json'
EXEMPTIONS = ROOT / 'manifests' / 'help_exemptions.json'
INVENTORY = ROOT / 'manifests' / 'help_inventory.json'

STATUSES = ('complete', 'partial', 'not_started', 'excluded')

# High-traffic references a daily Neovim user hits first: editing and insert
# commands, options, mappings, autocommands, patterns, syntax, the Lua/API
# references and the quick index pages. Everything else is covered after these;
# the user manual tutorials (`usr_*`) form their own tier.
CORE_HIGH_TRAFFIC = frozenset({
    'api.txt', 'autocmd.txt', 'change.txt', 'cmdline.txt', 'editing.txt',
    'filetype.txt', 'fold.txt', 'gui.txt', 'helphelp.txt', 'indent.txt',
    'index.txt', 'insert.txt', 'intro.txt', 'lua.txt', 'map.txt',
    'message.txt', 'motion.txt', 'options.txt', 'pattern.txt', 'quickref.txt',
    'repeat.txt', 'starting.txt', 'syntax.txt', 'tagsrch.txt', 'treesitter.txt',
    'undo.txt', 'various.txt', 'vimfn.txt', 'visual.txt', 'vvars.txt',
    'windows.txt',
})

# Coarse topic labels, derived from the file name. They are metadata for
# planning coverage, not a translation statement.
TOPIC_RULES = (
    (re.compile(r'^usr_'), 'user-manual'),
    (re.compile(r'^usr_toc'), 'user-manual'),
    (re.compile(r'^ft_'), 'filetype-plugin'),
    (re.compile(r'^pi_'), 'packaged-plugin'),
    (re.compile(r'^if_'), 'legacy-interface'),
    (re.compile(r'^dev'), 'developer'),
    (re.compile(r'^(?:l10n|rileft|mlang|mbyte)'), 'localization'),
    (re.compile(r'^news'), 'release-notes'),
    (re.compile(r'^api'), 'api-reference'),
    (re.compile(r'^lua'), 'lua-reference'),
)

DEFAULT_TOPIC = 'reference'


def runtime_dir(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    value = os.environ.get('VIMRUNTIME')
    if value and (Path(value) / 'doc').is_dir():
        return Path(value)
    try:
        out = subprocess.run(
            [os.environ.get('NVIM_BIN', 'nvim'), '--headless', '-u', 'NONE',
             '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', '/tmp')},
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SystemExit(f'nvim runtime probe failed: {exc}') from exc
    if out.returncode != 0:
        detail = out.stderr.strip()[:400]
        raise SystemExit(f'nvim runtime probe exited {out.returncode}: {detail}')
    value = out.stdout.strip()
    if not value:
        raise SystemExit('nvim runtime probe returned an empty $VIMRUNTIME')
    runtime = Path(value)
    if not (runtime / 'doc').is_dir():
        raise SystemExit(f'{runtime}: nvim runtime probe returned a path without doc/')
    return runtime


def topic_for(name: str) -> str:
    for pattern, label in TOPIC_RULES:
        if pattern.search(name):
            return label
    return DEFAULT_TOPIC


def _digest(lines: list[str]) -> str:
    return hashlib.sha256('\n'.join(lines).encode('utf-8')).hexdigest()


# Bytes that make a line "blank" for footer purposes. Kept ASCII and identical
# to the Lua guard in 01_help_catalog_spec.lua so both sides hash one string.
BLANK = ' \t\r\f'


def footer_bytes(text: str) -> str:
    """The document footer: the last non-blank line plus every byte after it.

    The final modeline is part of the byte-level contract
    (tools/HELP_TRANSLATION_CONTRACT.md item 10), and a stray leading space or an
    extra trailing newline is invisible to the tag / example-block / link
    digests. Hashing from the last non-blank line to EOF covers both at once and
    is reproducible in Lua with ``vim.fn.sha256`` over the same string.
    """
    lines = text.split('\n')
    index = len(lines) - 1
    while index >= 0 and lines[index].strip(BLANK) == '':
        index -= 1
    return '\n'.join(lines[index:]) if index >= 0 else ''


def contract_fingerprint(text: str) -> dict:
    """The tag / example-block / link / footer contract of one pinned document.

    A translation must reproduce the upstream tag set, the ordered example-block
    bodies, the help-link multiset and the file footer byte for byte. Those four
    facts do not depend on which Neovim runs the test suite, so storing a digest
    lets tests/contract/help assert the contract on *every* version instead of only on
    the pinned runtime (a different runtime may not even ship the document).

    The digest must be reproducible in Lua with vim.fn.sha256; both sides hash
    UTF-8 bytes, sort by byte order and join with "\\n".
    """
    tag_names = sorted(set(parity.tags(text)), key=lambda value: value.encode('utf-8'))
    blocks = parity.example_blocks(text)
    links = parity.links(text)
    return {
        'tag_count': len(tag_names),
        'block_count': len(blocks),
        'link_count': sum(links.values()),
        'tags_digest': _digest(tag_names),
        'blocks_digest': _digest([hashlib.sha256(b.encode('utf-8')).hexdigest() for b in blocks]),
        'links_digest': _digest([f'{link}\t{links[link]}'
                                 for link in sorted(links, key=lambda v: v.encode('utf-8'))]),
        'tail_digest': hashlib.sha256(footer_bytes(text).encode('utf-8')).hexdigest(),
    }


def priority_for(name: str) -> int:
    if name in CORE_HIGH_TRAFFIC:
        return 1
    if name.startswith('usr_'):
        return 2
    return 3


def load_exemptions() -> dict[str, dict]:
    if not EXEMPTIONS.exists():
        return {}
    data = json.loads(EXEMPTIONS.read_text(encoding='utf-8'))
    if data.get('schema_version') != 1:
        raise SystemExit(f'{EXEMPTIONS}: unexpected schema_version')
    result: dict[str, dict] = {}
    for item in data.get('exemptions', []):
        name = item.get('file', '')
        if not name or not item.get('reason') or not item.get('evidence'):
            raise SystemExit(f'{EXEMPTIONS}: every exemption needs file, reason and evidence')
        if name in result:
            raise SystemExit(f'{EXEMPTIONS}: duplicate exemption for {name}')
        result[name] = item
    return result


def build_inventory(runtime: Path) -> dict:
    manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
    neovim = manifest['upstreams']['neovim']
    translated = {Path(v['source']).name: v for v in neovim['documents'].values()}
    exemptions = load_exemptions()

    documents = []
    for path in sorted((runtime / 'doc').glob('*.txt')):
        name = path.name
        raw = path.read_bytes()
        text = raw.decode('utf-8')
        entry = {
            'path': f'runtime/doc/{name}',
            'lines': text.count('\n') + (0 if text.endswith('\n') else 1),
            'bytes': len(raw),
            'sha256': hashlib.sha256(raw).hexdigest(),
            'tags': len(set(parity.tags(text))),
            'example_blocks': len(parity.example_blocks(text)),
            'help_links': sum(parity.links(text).values()),
            'topic': topic_for(name),
            'priority': priority_for(name),
            'status': 'not_started',
            'translation': None,
            'contract': None,
            'reason': None,
            'evidence': None,
        }
        meta = translated.get(name)
        if meta is not None:
            if meta['sha256'] != entry['sha256']:
                raise SystemExit(
                    f'{name}: manifest sha256 {meta["sha256"]} != runtime {entry["sha256"]}')
            entry['status'] = meta['status']
            entry['translation'] = meta['translation']
            # Derived from the pinned upstream, never from the translation: a
            # translation that already deviates must fail, not define the norm.
            entry['contract'] = contract_fingerprint(text)
        elif name in exemptions:
            entry['status'] = 'excluded'
            entry['reason'] = exemptions[name]['reason']
            entry['evidence'] = exemptions[name]['evidence']
        documents.append(entry)

    seen = {item['path'].removeprefix('runtime/doc/') for item in documents}
    for name in sorted(set(translated) - seen):
        raise SystemExit(f'{name}: manifest lists a document that is not in $VIMRUNTIME/doc')
    for name in sorted(set(exemptions) - seen):
        raise SystemExit(f'{name}: exemption names a document that is not in $VIMRUNTIME/doc')

    totals = {'documents': len(documents), 'lines': sum(d['lines'] for d in documents),
              'tags': sum(d['tags'] for d in documents),
              'example_blocks': sum(d['example_blocks'] for d in documents),
              'help_links': sum(d['help_links'] for d in documents)}
    for status in STATUSES:
        rows = [d for d in documents if d['status'] == status]
        totals[status] = len(rows)
        totals[f'{status}_lines'] = sum(d['lines'] for d in rows)

    return {
        'schema_version': 1,
        'pinned': {'neovim': neovim['version'], 'commit': neovim['commit']},
        'notes': [
            'Generated by tools/help_inventory.py; do not edit by hand.',
            'status: complete/partial come from manifests/upstreams.json,',
            'excluded requires manifests/help_exemptions.json evidence, and',
            'everything else is normal user-facing help that is still not_started.',
            'contract: tag/example-block/link digests of the pinned upstream text,',
            'asserted against the translation on every Neovim version by the Help contract suite.',
        ],
        'totals': totals,
        'documents': documents,
    }


def render(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False) + '\n'


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if the inventory is stale')
    parser.add_argument('--runtime', help='$VIMRUNTIME to read (defaults to a probe)')
    parser.add_argument('--output', type=Path, default=INVENTORY)
    args = parser.parse_args(argv)

    data = build_inventory(runtime_dir(args.runtime))
    text = render(data)
    t = data['totals']
    if args.check:
        current = args.output.read_text(encoding='utf-8') if args.output.exists() else ''
        if current != text:
            print(f'HELP_INVENTORY=STALE {args.output}', file=sys.stderr)
            return 1
        print(f'HELP_INVENTORY=OK documents={t["documents"]} complete={t["complete"]} '
              f'partial={t["partial"]} not_started={t["not_started"]} excluded={t["excluded"]}')
        return 0
    atomic_write_text(args.output, text)
    print(f'HELP_INVENTORY=WRITTEN {args.output} documents={t["documents"]} '
          f'complete={t["complete"]} partial={t["partial"]} '
          f'not_started={t["not_started"]} excluded={t["excluded"]} '
          f'lines={t["lines"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
