#!/usr/bin/env python3
"""Build and maintain fixed upstream adapters."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from collections import Counter
from pathlib import Path

import adapter_manifest as manifest
import help_parity
from adapter_manifest import AdapterError, expect
from catalog_tool import atomic_write_bytes, check as check_catalogs, parse_po

ROOT = manifest.ROOT


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def build(root, adapters):
    atomic_write_bytes(root / manifest.INDEX, manifest.index_text(adapters).encode())


def fetch(lock, base):
    expect(lock['schema'] == 1, 'unsupported source lock schema')
    if 'targets' in lock:
        for entry in lock['targets']:
            fetch({'schema': 1, **entry}, base)
        return lock
    for id, source in lock['sources'].items():
        expect(manifest.ID.fullmatch(id) and manifest.SHA.fullmatch(source['commit'])
               and manifest.REPO.fullmatch(source['repository']), f'{id}: invalid source lock')
        destination = base / id / source['commit']
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            repo = source['repository'].removeprefix('https://github.com/')
            with urllib.request.urlopen(f'https://codeload.github.com/{repo}/tar.gz/{source["commit"]}',
                                        timeout=60) as response:
                archive = response.read()
            with tempfile.TemporaryDirectory(dir=destination.parent) as stage:
                tree = Path(stage) / 'source'
                tree.mkdir()
                with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
                    for member in tar:
                        parts = manifest.relative(member.name.rstrip('/')).parts
                        if len(parts) == 1:
                            continue
                        expect(member.isfile() or member.isdir(), f'unsupported archive member: {member.name}')
                        member.name = '/'.join(parts[1:])
                        tar.extract(member, tree, filter='data')
                tree.rename(destination)
        manifest.checked_source(base, id, source, allow_unpinned=True)
    return lock


def discover(spec):
    repo = spec['upstream']['repository']
    if spec['upstream']['follow']['kind'] == 'default_branch':
        result = subprocess.check_output(['git', 'ls-remote', repo, 'HEAD'], text=True, timeout=60)
        commit = result.split()[0]
    else:
        result = subprocess.check_output(['git', 'ls-remote', '--tags', repo], text=True, timeout=60)
        tags = {}
        for line in result.splitlines():
            sha, ref = line.split()
            match = re.fullmatch(r'refs/tags/v?(\d+)\.(\d+)\.(\d+)(\^\{\})?', ref)
            if match:
                version = tuple(int(part) for part in match.groups()[:3])
                if version not in tags or match[4]:
                    tags[version] = sha
        expect(tags, 'no stable release tags')
        commit = tags[max(tags)]
    expect(manifest.SHA.fullmatch(commit), 'upstream did not return a full commit')
    return commit


def audit(root, spec, baseline, lock, base):
    id = spec['id']
    expect(lock['schema'] == 1 and lock['id'] == id, 'candidate lock belongs to a different adapter')
    old = manifest.checked_source(base, id, baseline['sources'][id])
    new = manifest.checked_source(base, id, lock['sources'][id], allow_unpinned=True)
    sources = baseline['sources'][id]['sources']
    diagnostics = []
    paths = set(sources)
    for path in (old, new):
        paths.update(str(p.relative_to(path)) for p in path.rglob('*')
                     if p.is_file() and not p.is_symlink()
                     and p.suffix in ('.lua', '.vim', '.txt', '.cnx'))
    for relative in sorted(paths):
        before, after = old / relative, new / relative
        old_bytes = before.read_bytes() if before.is_file() else None
        new_bytes = after.read_bytes() if after.is_file() else None
        if old_bytes == new_bytes:
            continue
        surfaces = [name for name, value in spec['surfaces'].items()
                    if relative in value.get('modules', {}).values()]
        if not surfaces:
            surfaces = sorted(spec['surfaces'])
        old_lines = (old_bytes or b'').decode(errors='replace').splitlines()
        new_lines = (new_bytes or b'').decode(errors='replace').splitlines()
        import difflib
        first = next((b + 1 for kind, _, _, b, _ in
                      difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False).get_opcodes()
                      if kind != 'equal'), 1)
        diagnostics.append(dict(code='source_changed' if old_bytes and new_bytes else
                                'source_added' if new_bytes is not None else 'source_removed',
                                file=relative, line=first, surfaces=surfaces,
                                scenarios=[key for key, case in spec['scenarios'].items()
                                           if set(case['surfaces']) & set(surfaces)]))
    if spec.get('domain'):
        po = root / f'translations/po/zh_CN/{spec["domain"]}.po'
        for entry in parse_po(po)[0]:
            for ref in entry['references']:
                relative, _, line = ref.partition(':')
                if relative in paths and (not (new / relative).is_file()
                        or (old / relative).is_file() and (old / relative).read_bytes() != (new / relative).read_bytes()):
                    diagnostics.append(dict(code='review_po_reference', file=str(po.relative_to(root)),
                                            source=relative, line=int(line) if line.isdecimal() else None,
                                            context=entry.get('msgctxt', ''), msgid=entry['msgid']))
    candidate = dict(lock['sources'][id])
    candidate['sources'] = {name: hashlib.sha256((new / name).read_bytes()).hexdigest()
                            for name in sorted(paths) if (new / name).is_file() and not (new / name).is_symlink()}
    candidate_lock = {**lock, 'sources': {**lock['sources'], id: candidate}}
    return dict(schema=1, id=id, baseline=baseline['sources'][id]['commit'],
                candidate=lock['sources'][id]['commit'], candidate_lock=candidate_lock, diagnostics=diagnostics)


def env_for(root, temp, source_dirs, binary):
    env = dict(os.environ, NVIM_ZH_ROOT=str(root), NVIM_BIN=binary, PYTHONDONTWRITEBYTECODE='1',
               PYTHONPATH=os.pathsep.join(str(root / item) for item in ('tools', 'tests/support', 'tests/tools')),
               NVIM_LOG_FILE=str(temp / 'nvim.log'), NVIM_ZH_TMP=str(temp), TMPDIR=str(temp))
    for key in ('STATE', 'DATA', 'CONFIG', 'CACHE', 'RUNTIME'):
        path = temp / key.lower()
        path.mkdir(mode=0o700)
        env[f'XDG_{key}_HOME'] = str(path)
    for id, directory in source_dirs.items():
        name = 'LAZY' if id == 'lazy.nvim' else re.sub(r'[^A-Z0-9]', '_', id.upper())
        env['NVIM_ZH_TEST_' + name] = str(directory)
    return env


def run_case(root, binary, script, dirs, extra=()):
    with tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-') as temp:
        env = env_for(root, Path(temp), dirs, binary)
        if script.endswith('.lua'):
            command = [binary, '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
                       '--cmd', "lua vim.opt.rtp:prepend(vim.env.NVIM_ZH_ROOT)",
                       '--cmd', 'runtime plugin/nvim-zh.lua', '-l', str(root / script)]
        else:
            command = [sys.executable, str(root / script), *extra]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        return result.returncode, result.stdout + result.stderr


def check_runtime_pins(runtime, sources):
    for path, digest in sources.items():
        if path.startswith('lua/vim/'):
            data = manifest.owned(runtime, path, '').read_bytes()
            expect(hashlib.sha256(data).hexdigest() == digest, f'{path}: Neovim runtime source hash changed')


def check_help_excerpt(id, name, original, translated, tags):
    expect(tags - {name} <= manifest.help_tags(original), f'{id}/{name}: changed upstream Help tag')
    translations = Counter(help_parity.links(translated))
    expect(not translations - Counter(help_parity.links(original)), f'{id}/{name}: changed upstream Help link')
    blocks = Counter(block.strip('\n') for block in help_parity.example_blocks(translated))
    upstream = Counter(block.strip('\n') for block in help_parity.example_blocks(original))
    expect(not blocks - upstream, f'{id}/{name}: changed upstream Help example')


def check_references(root, spec, upstream=None, runtime=None):
    domain = spec.get('domain')
    if not domain:
        return
    po = root / f'translations/po/zh_CN/{domain}.po'
    external = spec.get('runtime_references', {})
    lines = {}
    for entry in parse_po(po)[0]:
        expect(entry['references'], f'{po}: missing reference for {entry["msgid"]!r}')
        for reference in entry['references']:
            path, sep, number = reference.partition(':')
            expect(not sep or number.isdecimal() and int(number) > 0, f'{po}: invalid reference {reference!r}')
            expect(path in external or all(path in combo['sources'] for combo in spec['targets'].values()),
                   f'{po}: unpinned reference {reference!r}')
            if upstream and path not in lines:
                if path in external:
                    source = external[path]
                    data = manifest.owned(runtime, source['path'], '').read_bytes()
                    expect(hashlib.sha256(data).hexdigest() == source['sha256'], f'{path}: Neovim source hash changed')
                elif path.startswith('lua/vim/'):
                    data = manifest.owned(runtime, path, '').read_bytes()
                else:
                    data = manifest.owned(upstream, path, '').read_bytes()
                lines[path] = len(data.splitlines())
            if upstream and sep:
                expect(int(number) <= lines[path], f'{po}: reference is outside source: {reference}')
    if upstream:
        for id, source, document, tags in manifest.help_inputs(root, {spec['id']: spec}):
            original = manifest.owned(upstream, source, 'doc/').read_text(encoding='utf-8')
            check_help_excerpt(id, document.name, original, document.read_text(encoding='utf-8'), tags)


def run_tests(args, adapters, shared):
    if args.candidate:
        lock = manifest.read(args.candidate)
        expect(args.upstream and args.id != 'all' and lock['id'] == args.id and lock['schema'] == 1,
               '--candidate requires one matching upstream adapter')
        target = args.target or lock['target']
        expected = manifest.target_lock(adapters, shared, args.id, target)
        expect(set(lock['sources']) == set(expected['sources']) and lock['neovim'] == expected['neovim']
               and all(source == expected['sources'][name] for name, source in lock['sources'].items()
                       if name != args.id), 'invalid candidate validation inputs')
        source = lock['sources'][args.id]
        expect(source['repository'] == expected['sources'][args.id]['repository'], 'candidate repository changed')
        expect(source['sources'], 'candidate needs source digests from audit')
        with tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-candidate-') as temp:
            tree = Path(temp) / 'repo'
            shutil.copytree(args.root, tree, ignore=shutil.ignore_patterns('.git', '.agents', '.aws', '.codex', '__pycache__'))
            path = tree / f'manifests/adapters/{args.id}.json'
            draft = manifest.read(path)
            draft['targets'][target].update(commit=source['commit'], sources=source['sources'])
            atomic_write_bytes(path, encoded(draft))
            staged = manifest.validate(tree)
            build(tree, staged)
            import resource_bundle
            resource_bundle.write(tree / 'resources', resource_bundle.contents(tree))
            options = argparse.Namespace(**{**vars(args), 'root': tree, 'candidate': None, 'target': target})
            result = run_tests(options, staged, shared)
            result['candidate'] = source['commit']
            return result
    names = sorted(adapters) if args.id == 'all' else [args.id]
    root = args.root
    binary = os.environ.get('NVIM_BIN', 'nvim')
    records = []
    for id in names:
        spec = adapters[id]
        if spec['status'] == 'draft' or args.offline and spec['status'] != 'implemented':
            continue
        if args.offline:
            paths = sorted((root / f'tests/contract/plugins/{id}').glob('*_spec.lua'))
            expect(paths, f'{id}: no offline contract')
            tests = [(str(path.relative_to(root)), ()) for path in paths]
            combos = [('offline', {}, tests, None)]
        else:
            combos = []
            for target in ([args.target] if args.target else spec['targets']):
                lock = manifest.target_lock(adapters, shared, id, target)
                expect(args.source_root is not None, '--upstream requires --source-root')
                dirs = {name: manifest.checked_source(args.source_root, name, source)
                        for name, source in lock['sources'].items()}
                with tempfile.TemporaryDirectory(prefix='nvim-zh-adapter-version-') as temp:
                    env = env_for(root, Path(temp), {}, binary)
                    version = subprocess.check_output([binary, '--version'], env=env, text=True, timeout=10)
                    runtime = subprocess.check_output([binary, '--headless', '-u', 'NONE', '-i', 'NONE',
                                '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa'], env=env, text=True, timeout=10)
                expect(version.splitlines()[0].removeprefix('NVIM v') == lock['neovim'],
                       f'{id}/{target}: expected Neovim {lock["neovim"]}')
                runtime = Path(runtime.strip()).resolve()
                for source in lock['sources'].values():
                    check_runtime_pins(runtime, source['sources'])
                check_references(root, spec, dirs[id], runtime)
                if spec['status'] == 'implemented':
                    expect(spec['scenarios'], f'{id}: missing required TUI scenarios')
                tests = [(test, ()) for test in spec['contracts']]
                tests.extend((scenario['tui'], (case,)) for case, scenario in spec['scenarios'].items())
                combos.append((target, dirs, tests, lock))
        for target, dirs, tests, lock in combos:
            for script, extra in tests:
                print(f'{id}/{target} {script} {" ".join(extra)}', file=sys.stderr, flush=True)
                try:
                    code, logs = run_case(root, binary, script, dirs, extra)
                except subprocess.TimeoutExpired as failure:
                    code, logs = 1, f'timeout: {failure}'
                if code == 0 and extra:
                    case = extra[0]
                    expected = f'TUI=PASS adapter={id} case={case} '
                    modes = ('enabled=false ', 'enabled=true ') if spec['scenarios'][case].get('differential', True) else ('',)
                    if any(not any(line.startswith(expected + mode) for line in logs.splitlines()) for mode in modes):
                        code, logs = 1, f'{logs}\nMissing terminal evidence for {id}/{case}\n'
                print(logs, file=sys.stderr, end='' if logs.endswith('\n') else '\n')
                records.append(dict(id=id, target=target, script=script, scenario=extra[0] if extra else None,
                                    commit=lock['sources'][id]['commit'] if lock else None,
                                    neovim=lock['neovim'] if lock else None,
                                    revisions={name: source['commit'] for name, source in lock['sources'].items()}
                                    if lock else None,
                                    status='PASS' if code == 0 else 'FAIL', log=logs))
    expect(records, 'no applicable adapter tests')
    return dict(schema=1, status='PASS' if all(row['status'] == 'PASS' for row in records) else 'FAIL',
                implementation=manifest.read(root / 'resources/manifest.json')['implementation']['id'],
                release_revision=os.environ.get('GITHUB_SHA'),
                results=records)


def watch(args, adapters, shared):
    args.report_dir.mkdir(parents=True, exist_ok=True)
    reports = []
    for id, spec in adapters.items():
        if spec['status'] != 'implemented':
            continue
        baseline = manifest.target_lock(adapters, shared, id, 'baseline')
        try:
            commit = discover(spec)
            if commit == baseline['sources'][id]['commit']:
                report = dict(id=id, status='UNCHANGED', commit=commit)
            else:
                candidate = manifest.target_lock(adapters, shared, id, 'baseline', commit)
                fetch(baseline, args.source_root)
                fetch(candidate, args.source_root)
                report = audit(args.root, spec, baseline, candidate, args.source_root)
                lock = args.report_dir / (id + '.lock.json')
                atomic_write_bytes(lock, encoded(report['candidate_lock']))
                if args.test:
                    options = argparse.Namespace(root=args.root, id=id, offline=False, upstream=True,
                                                 target='baseline', candidate=lock, source_root=args.source_root)
                    report['tests'] = run_tests(options, adapters, shared)
                    report['status'] = report['tests']['status']
                else:
                    report['status'] = 'AUDITED'
        except (OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as exc:
            report = dict(id=id, status='FAIL', error=str(exc))
        atomic_write_bytes(args.report_dir / (id + '.json'), encoded(report))
        reports.append(dict(id=id, status=report['status']))
    return dict(schema=1, status='FAIL' if any(row['status'] == 'FAIL' for row in reports) else 'PASS',
                results=reports)


def remove(root, adapters, id, plan):
    spec = adapters[id]
    expect(not any(id in target['dependencies'] for name, other in adapters.items() if name != id
                   for target in other['targets'].values()), f'{id} is still a dependency')
    files = {f'manifests/adapters/{id}.json'}
    if spec.get('entry'):
        files.add('lua/' + spec['entry'].replace('.', '/') + '.lua')
    if spec.get('domain'):
        files.add(f'translations/po/zh_CN/{spec["domain"]}.po')
        files.add(f'lua/nvim-zh/catalogs/generated/{spec["domain"]}.lua')
    files.update(row['tui'] for row in spec['scenarios'].values())
    files.update(spec['contracts'])
    for folder in (f'tests/contract/plugins/{id}', f'translations/help/adapters/{id}'):
        files.update(str(p.relative_to(root)) for p in (root / folder).rglob('*') if p.is_file())
    summary = dict(id=id, files=sorted(files), build=['make build-resources'])
    if plan:
        return summary
    removed = {}
    try:
        for name in sorted(files):
            if (root / name).exists():
                path = manifest.owned(root, name, '')
                removed[path] = path.read_bytes()
                path.unlink()
        build(root, manifest.validate(root))
    except (OSError, ValueError, KeyError, TypeError):
        for path, data in removed.items():
            atomic_write_bytes(path, data)
        raise
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('list', 'show', 'scaffold', 'build', 'check', 'lock', 'discover', 'fetch', 'audit', 'test', 'remove', 'watch'):
        cmd = sub.add_parser(name)
        cmd.add_argument('--json', action='store_true', help='emit JSON to stdout')
        if name in ('show', 'scaffold', 'lock', 'discover', 'audit', 'test', 'remove'):
            cmd.add_argument('id')
        if name == 'scaffold':
            cmd.add_argument('--repo', required=True)
            cmd.add_argument('--commit', required=True)
        if name in ('audit', 'test'):
            cmd.add_argument('--candidate', type=Path, required=name == 'audit')
        if name in ('audit', 'fetch', 'test', 'watch'):
            cmd.add_argument('--source-root', type=Path, required=name != 'test')
        if name in ('lock', 'discover', 'audit', 'test'):
            cmd.add_argument('--target', default=None if name == 'test' else 'baseline')
        if name == 'fetch':
            cmd.add_argument('--lock', type=Path, required=True)
        if name == 'test':
            modes = cmd.add_mutually_exclusive_group(required=True)
            modes.add_argument('--offline', action='store_true')
            modes.add_argument('--upstream', action='store_true')
        if name == 'check':
            cmd.add_argument('id', nargs='?')
        if name == 'remove':
            cmd.add_argument('--plan', action='store_true')
        if name == 'watch':
            cmd.add_argument('--report-dir', type=Path, required=True)
            cmd.add_argument('--test', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    args.root = root
    if hasattr(args, 'source_root') and args.source_root:
        args.source_root = args.source_root.resolve()
    try:
        command = args.command
        if command == 'fetch':
            result = fetch(manifest.read(args.lock), args.source_root)
        elif command == 'scaffold':
            expect(manifest.ID.fullmatch(args.id) and manifest.REPO.fullmatch(args.repo)
                   and manifest.SHA.fullmatch(args.commit), 'invalid id, repository or commit')
            path = root / f'manifests/adapters/{args.id}.json'
            expect(not path.exists(), f'adapter already exists: {args.id}')
            neovim = manifest.read(root / 'manifests/upstreams.json')['upstreams']['neovim']['version']
            data = dict(schema=1, id=args.id, status='draft', upstream=dict(repository=args.repo,
                        follow=dict(kind='default_branch')), targets=dict(baseline=dict(commit=args.commit,
                        neovim=neovim, dependencies=[], sources={})), modules=[], lazy_names=[], surfaces={},
                        scenarios={}, contracts=[])
            atomic_write_bytes(path, encoded(data))
            result = dict(id=args.id, file=str(path.relative_to(root)), status='draft')
        else:
            adapters = manifest.validate(root)
            shared = manifest.dependencies(root)
            id = getattr(args, 'id', None)
            spec = adapters.get(id)
            expect(id is None or spec is not None or (command in ('test', 'lock') and id == 'all'),
                   f'unknown adapter: {id}')
            if command == 'list':
                result = {name: spec['status'] for name, spec in adapters.items()}
            elif command == 'show':
                result = spec
            elif command == 'build':
                build(root, adapters)
                result = dict(status='PASS', index=str(manifest.INDEX))
            elif command == 'check':
                expect((root / manifest.INDEX).read_text() == manifest.index_text(adapters), 'adapter index is stale')
                check_catalogs(root / 'translations/po/zh_CN', root / 'translations/glossary/zh_CN.toml')
                for name in ([id] if id else adapters):
                    check_references(root, adapters[name])
                result = dict(status='PASS', id=id)
            elif command in ('lock', 'discover', 'audit'):
                if id == 'all':
                    result = manifest.suite_lock(adapters, shared)
                else:
                    candidate = discover(spec) if command == 'discover' else None
                    result = manifest.target_lock(adapters, shared, id, args.target, candidate)
                if command == 'audit':
                    result = audit(root, spec, result, manifest.read(args.candidate), args.source_root)
            elif command == 'test':
                result = run_tests(args, adapters, shared)
            elif command == 'watch':
                result = watch(args, adapters, shared)
            else:
                result = remove(root, adapters, id, args.plan)
        print(encoded(result).decode(), end='')
        return 1 if result.get('status') == 'FAIL' else 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError) as exc:
        if args.json:
            print(encoded(dict(schema=1, status='FAIL', code='adapter_error', error=str(exc))).decode(), end='')
        else:
            print(f'ADAPTER=FAIL {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
