#!/usr/bin/env python3
"""Read-only source evidence for the fixed nvim-cmp inventory-only decision."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()


def require(condition: bool, message: str) -> None:
    """Keep gate checks active under PYTHONOPTIMIZE and python -O."""
    if not condition:
        raise AssertionError(message)


upstream = os.environ.get('NVIM_ZH_TEST_NVIM_CMP')
if not upstream:
    print('CMP_PUBLIC_SEAM_SMOKE=FAIL set NVIM_ZH_TEST_NVIM_CMP=/fixed/nvim-cmp')
    raise SystemExit(1)
root = Path(upstream).resolve()
manifest = json.loads((ROOT / 'manifests' / 'upstreams.json').read_text(encoding='utf-8'))['upstreams']['nvim-cmp']
require(manifest['commit'] == '2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3', 'unexpected nvim-cmp commit')
require(manifest['adapter']['status'] == 'inventory_only', 'nvim-cmp adapter policy changed')
require('lua/cmp/entry.lua' in manifest['sources'], 'nvim-cmp entry.lua is not pinned')
for name, metadata in manifest['sources'].items():
    data = (root / name).read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    require(actual == metadata['sha256'], f'{name}: {actual} != {metadata["sha256"]}')
default = (root / 'lua/cmp/config/default.lua').read_text(encoding='utf-8')
entry = (root / 'lua/cmp/entry.lua').read_text(encoding='utf-8')
require('format = function(_, vim_item)\n        return vim_item\n      end' in default,
        'nvim-cmp default formatter seam changed')
for field in ('abbr', 'kind', 'menu'):
    require(f'vim_item.{field} = str.oneline' in entry, f'nvim-cmp source field changed: {field}')
print(f'CMP_PUBLIC_SEAM_SMOKE=PASS nvim-cmp=2ffe79f hashes={len(manifest["sources"])} formatter=identity source_fields=abbr,kind,menu adapter=inventory_only')
