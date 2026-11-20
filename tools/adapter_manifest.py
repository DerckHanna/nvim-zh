"""Source of truth for adapter builds, source verification and test selection."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
INDEX = Path('manifests/adapter-index.lua')
ID = re.compile(r'[a-z0-9][a-z0-9_.-]*\Z')
SHA = re.compile(r'[a-f0-9]{40}\Z')
DIGEST = re.compile(r'[a-f0-9]{64}\Z')
REPO = re.compile(r'https://github\.com/[\w.-]+/[\w.-]+\Z', re.ASCII)
STATUS = {'implemented', 'inventory_only', 'draft'}


class AdapterError(ValueError):
    pass


def expect(condition, message):
    if not condition:
        raise AdapterError(message)


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def relative(name, prefix=''):
    expect(isinstance(name, str) and '\\' not in name and name.startswith(prefix)
           and not name.startswith('/') and all(p not in ('', '.', '..') for p in name.split('/')),
           f'invalid relative path: {name!r}')
    return PurePosixPath(name)


def owned(root, name, prefix):
    path = root / relative(name, prefix)
    expect(path.is_file() and path.resolve().is_relative_to(root.resolve())
           and not any(p.is_symlink() for p in [path, *path.parents] if p != root and root in p.parents),
           f'missing or unsafe adapter file: {name}')
    return path


def load(root=ROOT):
    folder = root / 'manifests/adapters'
    return {path.stem: read(path) for path in sorted(folder.glob('*.json'))}


def upstreams(path):
    """Include the baseline adapter sources in the catalog maintenance inventory."""
    manifest = read(path)
    for id, spec in load(path.parent.parent).items():
        if spec['status'] == 'draft':
            continue
        target = spec['targets']['baseline']
        manifest['upstreams'][id] = dict(spec['upstream'], commit=target['commit'],
                                         adapter=spec.get('notes', {}),
                                         sources={p: {'sha256': sha} for p, sha in target['sources'].items()})
    return manifest


def po_sources(root=ROOT):
    return {
        spec['domain']: root / 'translations/po/zh_CN' / (spec['domain'] + '.po')
        for spec in load(root).values() if spec['status'] == 'implemented'
    }


def dependencies(root=ROOT):
    return read(root / 'manifests/upstreams.json')['test_dependencies']


def help_inputs(root, adapters):
    tags = set()
    for path in (root / 'doc').glob('*.cnx'):
        if path.is_file():
            tags.update(help_tags(path.read_text(encoding='utf-8')))
    for id, spec in adapters.items():
        for source, documents in spec.get('help', {}).items():
            relative(source, 'doc/')
            expect(all(source in target['sources'] for target in spec['targets'].values()),
                   f'{id}: Help source is not pinned: {source}')
            for name in documents:
                expect(re.fullmatch(r'[a-zA-Z0-9_.-]+\.cnx', name), f'{id}: invalid Help filename')
                path = owned(root, f'translations/help/adapters/{id}/{name}', 'translations/help/adapters/')
                names = help_tags(path.read_text(encoding='utf-8'))
                expect(names and not tags.intersection(names), f'{id}: missing or conflicting Help tags: {name}')
                tags.update(names)
                yield id, source, path, names


def help_tags(text):
    return set(re.findall(r'(?<!\S)\*([^\s*|]+)\*(?=\s|$)', text))


def validate(root=ROOT):
    adapters, shared = load(root), dependencies(root)
    seen = set()
    owned_files, module_sources = set(), {}
    for id, spec in adapters.items():
        def require(condition, message):
            expect(condition, f'{id}: {message}')

        require(ID.fullmatch(id) and id != 'all' and spec['id'] == id and spec['schema'] == 1, 'invalid id or schema')
        status = spec['status']
        require(status in STATUS, 'invalid status')
        upstream = spec['upstream']
        require(REPO.fullmatch(upstream['repository']), 'expected an explicit GitHub repository')
        require(upstream['follow']['kind'] in ('default_branch', 'release'), 'unknown tracking policy')
        require('baseline' in spec['targets'], 'missing baseline')
        for path in spec['contracts']:
            owned(root, path, f'tests/upstream/{id}/')
        for target, combo in spec['targets'].items():
            require(ID.fullmatch(target) and SHA.fullmatch(combo['commit']), f'invalid target: {target}')
            require(re.fullmatch(r'\d+\.\d+\.\d+', combo['neovim']), 'expected a fixed Neovim version')
            require(set(combo['dependencies']) <= adapters.keys() | shared.keys(), 'unknown dependency')
            require(id not in combo['dependencies'], 'self dependency')
            for source, sha in combo['sources'].items():
                relative(source)
                require(DIGEST.fullmatch(sha), f'invalid source digest: {source}')
            require(status == 'draft' or combo['sources'], f'target {target} has no reviewed sources')
        if status != 'implemented':
            require(not spec.get('entry') and not spec['surfaces'] and not spec['scenarios'],
                    'inactive adapter defines runtime surfaces')
            continue
        domain = spec['domain']
        require(ID.fullmatch(domain) and domain not in seen and domain not in ('nvim-ui', 'clangd', 'clang', 'clang-tidy', 'nvim-zh'),
                'invalid or duplicate domain')
        seen.add(domain)
        entry = spec['entry']
        require(re.fullmatch(r'nvim-zh\.adapters\.[a-z][a-z_0-9]*', entry)
                and entry.split('.')[-1] not in ('common', 'index', 'evidence', 'scope'), 'invalid Lua entry')
        entry_path = owned(root, 'translations/adapters/' + entry.split('.')[-1] + '.lua', 'translations/adapters/')
        require(type(spec.get('source_projection', False)) is bool, 'invalid source projection')
        require(entry_path not in owned_files, 'Lua entry already owned')
        owned_files.add(entry_path)
        owned(root, f'translations/po/zh_CN/{domain}.po', 'translations/po/zh_CN/')
        require(spec['modules'] and all(ID.fullmatch(name) for name in spec['modules']), 'invalid module probes')
        covered = set()
        for case, scenario in spec['scenarios'].items():
            require(ID.fullmatch(case) and scenario['surfaces']
                    and set(scenario['surfaces']) <= spec['surfaces'].keys(), f'invalid scenario: {case}')
            require(type(scenario.get('differential', True)) is bool, f'invalid TUI scenario mode: {case}')
            covered.update(scenario['surfaces'])
            owned(root, scenario['tui'], f'tests/upstream/{id}/')
        require(covered and covered == spec['surfaces'].keys(), 'all enabled surfaces require a TUI scenario')
        for name, surface in spec['surfaces'].items():
            require(ID.fullmatch(name) and surface['kind'] in ('api', 'versioned', 'help'), f'invalid surface: {name}')
            if surface['kind'] == 'help':
                require(spec.get('help'), 'Help surface has no source')
            if 'source' in surface:
                # A plugin may dispatch notifications from more than one pin:
                # each declared origin must be a pinned relative path.
                origins = surface['source']
                if isinstance(origins, str):
                    origins = [origins]
                require(isinstance(origins, list) and origins, f'{name} has an invalid source')
                for origin in origins:
                    relative(origin)
                    require(all(origin in target['sources'] for target in spec['targets'].values()),
                            f'{name} has an unpinned source')
            if surface['kind'] == 'versioned':
                require(type(surface.get('independent', False)) is bool, 'invalid independent source group')
                sources = surface['modules']
                require(sources and all(ID.fullmatch(module) for module in sources), f'{name} has no runtime sources')
                require(all(set(sources.values()) <= target['sources'].keys()
                            for target in spec['targets'].values()), f'{name} has unpinned runtime sources')
                for module, source in sources.items():
                    if not module.startswith('vim.'):
                        owner = module_sources.setdefault(module, (id, source))
                        require(owner == (id, source), f'{name} conflicts with the source for {module}')
    for id, spec in adapters.items():
        for target in spec['targets']:
            target_lock(adapters, shared, id, target)
    list(help_inputs(root, adapters))
    return adapters


def runtime_specs(adapters):
    entries = {}
    for id, spec in adapters.items():
        if spec['status'] == 'draft':
            continue
        entry = {k: spec[k] for k in ('status', 'modules', 'lazy_names', 'surfaces', 'notes', 'help',
                                     'source_projection') if k in spec}
        entry.update({k: spec[k] for k in ('entry', 'domain') if k in spec})
        entry['repository'] = spec['upstream']['repository']
        entry['targets'] = {
            name: {k: combo[k] for k in ('commit', 'sources', 'neovim')}
            for name, combo in spec['targets'].items()
        }
        entries[id] = entry
    return entries


def index_text(adapters):
    payload = json.dumps(runtime_specs(adapters), ensure_ascii=True, separators=(',', ':'), sort_keys=True)
    delimiter = '='
    while f']{delimiter}]' in payload:
        delimiter += '='
    return f'-- Generated by adapter_tool.py build.\nreturn vim.json.decode([{delimiter}[{payload}]{delimiter}])\n'


def target_lock(adapters, shared, id, target, candidate=None):
    combos = {}

    def add(name, choice, chain):
        expect(name not in chain, 'adapter dependency cycle: ' + ' -> '.join((*chain, name)))
        if name in combos:
            return
        if name in shared:
            value = shared[name]
            combos[name] = dict(repository=value['repository'], commit=value['commit'],
                                sources={key: item['sha256'] for key, item in value['sources'].items()})
            return
        spec = adapters[name]
        combo = spec['targets'][choice]
        for dep in combo['dependencies']:
            add(dep, 'baseline', (*chain, name))
        combos[name] = dict(repository=spec['upstream']['repository'],
                            commit=candidate if name == id and candidate else combo['commit'],
                            sources={} if name == id and candidate else combo['sources'])

    add(id, target, ())
    return dict(schema=1, id=id, target=target, neovim=adapters[id]['targets'][target]['neovim'],
                sources=combos)


def suite_lock(adapters, shared):
    sources = {}
    for id, spec in adapters.items():
        if spec['status'] == 'draft':
            continue
        for target in spec['targets']:
            for name, source in target_lock(adapters, shared, id, target)['sources'].items():
                sources.setdefault(name, {})[source['commit']] = source
    return {'schema': 1, 'targets': [{'sources': {name: source}} for name, revisions in sources.items()
                                    for source in revisions.values()]}


def checked_source(base, id, source, *, allow_unpinned=False):
    expect(ID.fullmatch(id) and SHA.fullmatch(source['commit']) and REPO.fullmatch(source['repository']),
           f'{id}: invalid locked revision or repository')
    tree = base / id / source['commit']
    expect(tree.is_dir() and tree.resolve().is_relative_to(base.resolve()), f'{id}: missing fixed source: {tree}')
    sources = source['sources']
    expect(sources or allow_unpinned, f'{id}: no pinned source digests')
    for path, sha in sources.items():
        if path.startswith('lua/vim/'):
            # Runtime-owned Neovim module pinned for a versioned surface. It is
            # verified against the actual runtime by check_references, not the
            # plugin source tree.
            continue
        file = owned(tree, path, '')
        expect(hashlib.sha256(file.read_bytes()).hexdigest() == sha, f'{id}:{path}: source digest mismatch')
    return tree
