"""Verify SDK 2 plugin candidates against the released SDK 1 attachments."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
from statistics import median
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PLUGINS = ('which-key', 'telescope', 'nvim-tree', 'nvim-dap', 'nvim-dap-ui', 'nvim-dap-view')
CANDIDATES = (*PLUGINS, 'nvim-cmp')


def read_rows(path):
    return json.loads(path.read_bytes())['packages']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(args, env):
    for name in ('candidate', 'repeat'):
        subprocess.run([sys.executable, str(ROOT / 'tools/pack_assets.py'),
                        '--sdk', '2', '--version', '0.2.0', '--index', str(args.catalog),
                        '--output', str(args.output / name),
                        *(arg for id in CANDIDATES for arg in ('--id', id))],
                       env=env, check=True, timeout=90)
    directory = args.output / 'candidate'
    repeat = args.output / 'repeat'
    files = sorted(p.name for p in directory.iterdir())
    if files != sorted(p.name for p in repeat.iterdir()):
        raise ValueError('candidate filenames differed')
    for filename in files:
        if (directory / filename).read_bytes() != (repeat / filename).read_bytes():
            raise ValueError(f'non-reproducible asset: {filename}')
    index = read_rows(directory / 'catalog.json')
    baseline = read_rows(args.catalog)
    additions = [row for row in index if row not in baseline]
    if len(index) != len(baseline) + len(CANDIDATES) or any(row not in index for row in baseline):
        raise ValueError('historical catalog rows changed')
    if {row['id'] for row in additions if (row['version'], row['locale'], row['sdk']) == ('0.2.0', 'zh_CN', 2)} != set(CANDIDATES):
        raise ValueError('SDK 2 catalog rows changed')
    for row in baseline:
        if row['id'] in PLUGINS:
            path = args.historical / (row['id'] + '-zh_CN.json')
            if (digest(path), path.stat().st_size) != (row['sha256'], row['size']):
                raise ValueError(f'historical attachment changed: {path}')
    print('PACKS_REPRODUCIBLE=PASS packs=7 rows=' + str(len(index)), flush=True)
    return directory, additions


def session(args, env, name, mode, **extra):
    directory = args.output / name
    config = dict(env, NVIM_ZH_P3_MODE=mode, NVIM_LOG_FILE=str(args.output / 'nvim.log'), **extra)
    config.update({f'XDG_{kind.upper()}_HOME': str(directory / kind)
                   for kind in ('config', 'cache', 'data', 'state')})
    config['NVIM_APPNAME'] = 'nvim'
    config.setdefault('NVIM_ZH_ROOT', str(ROOT))
    return subprocess.check_output(
        [os.environ.get('NVIM_BIN', 'nvim'), '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
         '-l', str(ROOT / 'tests/workflows/plugin_pack_migration.lua')],
        env=config, text=True, stderr=subprocess.STDOUT, timeout=60).strip()


def verify(args, env, additions):
    for name, mode in (('local', 'offline'), ('local', 'fresh'), ('remote', 'remote'), ('remote', 'fresh')):
        print(session(args, env, name, mode), flush=True)
    shutil.copytree(args.output / 'remote', args.output / 'corrupt')
    snapshots = args.output / 'corrupt/data/nvim/nvim-zh/packs/snapshots'
    for row in additions:
        if row['id'] in PLUGINS:
            path = snapshots / row['sha256'] / 'artifact.json'
            path.write_bytes(path.read_bytes() + b' ')
    for name, mode in (('corrupt', 'corrupt'), ('remote', 'rollback'), ('remote', 'rolled_back')):
        print(session(args, env, name, mode), flush=True)
    print(session(args, env, 'legacy', 'legacy', NVIM_ZH_ROOT=str(args.legacy_root)), flush=True)


def measure(args, env):
    samples = []
    for index in range(5):
        for id in PLUGINS:
            for sdk in (1, 2):
                output = session(args, env, f'{id}-{sdk}-{index}', 'measure',
                                 NVIM_ZH_P3_ID=id, NVIM_ZH_P3_SDK=str(sdk))
                samples.append(json.loads(output))
    rows = []
    for id in PLUGINS:
        for sdk in (1, 2):
            values = [row for row in samples if row['id'] == id and row['sdk'] == sdk]
            rows.append({'id': id, 'sdk': sdk, 'bytes': values[0]['bytes'],
                         **{key: median(row[key] for row in values)
                            for key in ('load_ms', 'rss_kib', 'lua_kib')}})
    (args.output / 'performance.json').write_text(json.dumps(
        {'samples': samples, 'median': rows}, indent=2) + '\n', encoding='utf-8')
    print('PACKS_SDK_COMPARISON=PASS packs=6 processes=60', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('catalog', 'historical', 'legacy-root', 'output'):
        parser.add_argument('--' + name, type=lambda value: Path(value).resolve(), required=True)
    args = parser.parse_args()
    if args.output.is_relative_to(ROOT) or args.output.exists():
        parser.error('--output must be a new directory outside the checkout')
    args.output.mkdir(parents=True)
    (args.output / 'locale').mkdir()
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', LOCPATH=str(args.output / 'locale'))
    env.pop('NVIM_ZH_ROOT', None)
    directory, additions = build(args, env)
    env.update(NVIM_ZH_P3_HISTORICAL=str(args.historical), NVIM_ZH_P3_CANDIDATE=str(directory))
    try:
        verify(args, env, additions)
        measure(args, env)
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.output) from error


if __name__ == '__main__':
    main()
