#!/usr/bin/env python3
"""Build/check the complete offline runtime payload shipped through vim.pack."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import catalog_tool as ct
import adapter_manifest as adapters

ROOT = Path(__file__).resolve().parents[1]


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def encoded_compact(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def index_id(files):
    return digest(''.join(f'{name}\0{item["sha256"]}\0{item["size"]}\n'
                          for name, item in sorted(files.items())).encode())


def descriptor(files):
    return {name: {'sha256': digest(data), 'size': len(data)} for name, data in sorted(files.items())}


def catalog(po, parsed=None):
    entries, headers = parsed if parsed is not None else ct.parse_po(po)
    entries = [dict(context=e.get('msgctxt', ''), msgid=e['msgid'], msgstr=e['msgstr'])
               for e in sorted(entries, key=lambda e: (e.get('msgctxt', ''), e['msgid']))]
    return dict(schema=1, domain=po.stem, locale='zh_CN',
                metadata={'source': po.name, 'headers': headers}, entries=entries)


def catalog_v2(po, parsed=None):
    entries, headers = parsed if parsed is not None else ct.parse_po(po)
    by_context = {}
    for entry in sorted(entries, key=lambda e: (e.get('msgctxt', ''), e['msgid'])):
        by_context.setdefault(entry.get('msgctxt', ''), {})[entry['msgid']] = entry['msgstr']
    return dict(schema=2, domain=po.stem, locale='zh_CN',
                metadata={'source': po.name, 'headers': headers}, entries=by_context)


def adapter_help(root, specs):
    files, help_tags = {}, {}
    for _, source, path, tags in adapters.help_inputs(root, specs):
        prefix = f'help/{Path(source).name}/doc/'
        files[prefix + path.name] = path.read_bytes()
        help_tags.setdefault(prefix, []).extend(f'{tag}\t{path.name}\t/*{tag}*\n' for tag in tags)
    for prefix, tags in help_tags.items():
        files[prefix + 'tags-cn'] = ''.join(sorted(tags)).encode()
    return files


def contents(root=ROOT):
    ct.check(root / 'translations/po/zh_CN', root / 'translations/glossary/zh_CN.toml')
    files, domains = {}, {}
    for domain, po in sorted(ct.builtin_sources(root).items()):
        source = catalog(po)
        files[f'catalogs/{domain}.json'] = encoded(source)
        domains[domain] = len(source['entries'])
    for source in sorted((root / 'doc').iterdir()):
        if source.suffix in {'.cnx', '.txt'} or source.name in {'tags', 'tags-cn'}:
            if source.is_symlink():
                raise ValueError(f'symlink resource: {source}')
            files['help/doc/' + source.name] = source.read_bytes()
    mo = root / 'build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
    files['native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'] = mo.read_bytes()
    inventory = json.loads((root / 'manifests/help_inventory.json').read_text())
    native = json.loads((root / 'manifests/native.json').read_text())
    # The MO probe must match the shipped intro translation exactly. Derive it
    # from intro.po (the source of truth) so editing the welcome screen cannot
    # leave a stale hardcoded probe that fails runtime validation.
    probe_msgid = 'type  :help nvim<Enter>     if you are new! '
    intro_entries, _ = ct.parse_po(root / native['intro']['po'])
    probe_msgstr = next(e['msgstr'] for e in intro_entries if e['msgid'] == probe_msgid)
    files['summary.json'] = encoded(dict(schema=1, domains=domains,
        help=inventory['totals'], baseline=inventory['pinned']['neovim'],
        native={'supplement': native['supplement']['entries'],
                'probe': {'msgid': probe_msgid, 'msgstr': probe_msgstr}}))
    implementation = {}
    for folder in ('lua', 'plugin', 'compiler'):
        folder_dir = root / folder
        if not folder_dir.exists():
            continue
        for source in sorted(folder_dir.rglob('*')):
            if not source.is_file():
                continue
            if not (source.name.endswith('.lua') or source.name.endswith('.vim')):
                continue
            if source.parent == root / 'lua/nvim-zh/catalogs/generated':
                continue  # PO-derived data is hot-swapped through JSON, not Lua code.
            if source.is_symlink():
                raise ValueError(f'symlink implementation: {source}')
            implementation[source.relative_to(root).as_posix()] = source.read_bytes()
    impl_index = descriptor(implementation)
    adapter_contract = index_id({name: value for name, value in impl_index.items()
                                 if name.startswith('lua/nvim-zh/adapters/') or name in (
                                     'lua/nvim-zh/plugins.lua', 'lua/nvim-zh/ui.lua', 'lua/nvim-zh/help.lua',
                                     'lua/nvim-zh/catalog.lua')})
    files['adapter-contract.json'] = encoded({'id': adapter_contract})
    resource_index = descriptor(files)
    manifest = dict(schema=1, runtime_api=1, version=(root / 'VERSION').read_text().strip(),
                    adapter_contract=adapter_contract,
                    implementation=dict(id=index_id(impl_index), files=impl_index),
                    bundle=dict(id=index_id(resource_index), files=resource_index))
    files['manifest.json'] = encoded(manifest)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['build', 'check'])
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    files = contents(args.root)
    output = args.root / 'resources'
    if args.command == 'check':
        actual = {p.relative_to(output).as_posix(): p.read_bytes()
                  for p in output.rglob('*') if p.is_file() and not p.is_symlink()}
        if actual != files or any(p.is_symlink() for p in output.rglob('*')):
            raise SystemExit('RESOURCE_BUNDLE=FAIL stale/missing/unexpected resource; run make build-resources')
        print(f'RESOURCE_BUNDLE=PASS {len(files)} files, deterministic payload')
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    # Each file is atomically replaced; manifest is published last. Users only
    # consume committed checkouts, and the runtime validates the entire payload.
    write(output, files)
    print(f'RESOURCE_BUNDLE=BUILT {len(files)} files')


def write(output, files):
    output.mkdir(exist_ok=True)
    for name, data in sorted(files.items(), key=lambda item: item[0] == 'manifest.json'):
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        ct.atomic_write_bytes(path, data)
    for path in sorted(output.rglob('*'), reverse=True):
        if path.is_file() and path.relative_to(output).as_posix() not in files:
            path.unlink()


if __name__ == '__main__':
    main()
