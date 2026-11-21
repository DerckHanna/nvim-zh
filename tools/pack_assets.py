#!/usr/bin/env python3
"""Build individual nvim-zh release assets and their catalog records."""
import argparse
import json
import re
from pathlib import Path

import adapter_manifest
import catalog_tool
import resource_bundle as bundle


def assets(root, version, repository, only=None, sdk=2):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('pack version must be major.minor.patch')
    if sdk not in (1, 2):
        raise ValueError(f'unsupported pack sdk: {sdk}')
    specs = adapter_manifest.validate(root)
    index = adapter_manifest.runtime_specs(specs)
    domains = catalog_tool.builtin_sources(root, optional=True)
    toolchain = json.loads((root / 'manifests/toolchain.json').read_text(encoding='utf-8'))
    upstreams = json.loads((root / 'manifests/upstreams.json').read_text(encoding='utf-8'))
    tools = {'clangd': upstreams['upstreams']['clangd']['tool']}
    tools.update(toolchain['tools'])
    parsed = {}
    catalog_tool.check(root / 'translations/po/zh_CN', root / 'translations/glossary/zh_CN.toml', parsed=parsed)
    ids = {id for id, spec in specs.items() if spec['status'] == 'implemented'} | set(tools)
    if only:
        selected = {only} if isinstance(only, str) else set(only)
        if selected - ids:
            raise ValueError(f'unknown packs: {", ".join(sorted(selected - ids))}')
        ids = selected
    tool_ids = ids & tools.keys()
    if tool_ids:
        import toolchain_catalog
        generated = toolchain_catalog.generate(root / 'manifests', root / 'translations/toolchain/zh_CN.json')
        for id in tool_ids:
            toolchain_catalog.verify_po(domains[id], toolchain_catalog.render(id, generated[id]))
    for id in sorted(ids):
        spec = index.get(id)
        domain = spec['domain'] if spec else id
        files = {}
        embedded_catalog = None
        if sdk == 1:
            files['catalogs/zh_CN.json'] = bundle.encoded(bundle.catalog(domains[domain], parsed[domains[domain]]))
        else:
            embedded_catalog = bundle.catalog_v2(domains[domain], parsed[domains[domain]])
        if spec:
            entry = spec['entry'].split('.')[-1]
            spec.pop('entry')
            files.update(bundle.adapter_help(root, {id: specs[id]}))
            files['adapter/entry.lua'] = (root / 'translations/adapters' / f'{entry}.lua').read_bytes()
        manifest = {'schema': 1, 'sdk': sdk, 'id': id, 'locale': 'zh_CN', 'version': version,
                    'domain': domain, 'name': id, 'files': bundle.descriptor(files)}
        if spec:
            manifest['adapter'] = spec
        else:
            manifest['executable'] = id
            manifest['tool'] = tools[id]
        decoded_files = {name: value.decode('utf-8') for name, value in files.items()}
        if sdk == 1:
            content = bundle.encoded({'manifest': manifest, 'files': decoded_files})
        else:
            content = bundle.encoded_compact({'manifest': manifest, 'catalog': embedded_catalog,
                                              'files': decoded_files})
        filename = f'{id}-zh_CN.json'
        record = {'id': id, 'version': version, 'locale': 'zh_CN', 'sdk': sdk, 'name': id,
                  'url': f'{repository}/releases/download/packs-{id}-v{version}/{filename}',
                  'sha256': bundle.digest(content), 'size': len(content)}
        if spec:
            record.update(repository=spec['repository'], modules=spec['modules'],
                          targets=sorted({target['commit'] for target in spec['targets'].values()}))
        else:
            record['executable'] = id
            record['tool'] = tools[id]
        yield filename, content, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=adapter_manifest.ROOT)
    parser.add_argument('--version', required=True)
    parser.add_argument('--sdk', type=int, choices=(1, 2), default=2,
                        help='attachment format (default: 2; 1 is for local compatibility tests)')
    parser.add_argument('--repository', default='https://github.com/DerckHanna/nvim-zh')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--id', action='append', help='select a pack to build (repeatable)')
    parser.add_argument('--index', type=Path, help='append to an existing published catalog')
    args = parser.parse_args()
    records = {}
    if args.index:
        index = json.loads(args.index.read_text(encoding='utf-8'))
        if index['schema'] != 1:
            parser.error('unsupported existing catalog schema')
        for item in index['packages']:
            key = item['id'], item['version'], item['locale']
            if key in records:
                parser.error(f'duplicate existing catalog version: {key}')
            records[key] = item
    args.output.mkdir(parents=True, exist_ok=True)
    for filename, content, record in assets(args.root, args.version, args.repository.rstrip('/'), args.id,
                                            sdk=args.sdk):
        key = record['id'], record['version'], record['locale']
        if key in records and records[key] != record:
            parser.error(f'{key[0]} {key[1]} already has a different asset')
        catalog_tool.atomic_write_bytes(args.output / filename, content)
        records[key] = record
    catalog_tool.atomic_write_bytes(args.output / 'catalog.json', bundle.encoded({
        'schema': 1, 'packages': [records[key] for key in sorted(records)]}))


if __name__ == '__main__':
    main()
