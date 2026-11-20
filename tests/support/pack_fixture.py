"""Install generated resource fixtures into an isolated test data directory."""
import json
import os
from pathlib import Path
import sys

from pack_assets import assets


def seed(root, data, only=None):
    base = data / os.environ.get('NVIM_APPNAME', 'nvim') / 'nvim-zh/packs'
    for _, content, record in assets(root, '1.0.0', 'https://example.invalid/nvim-zh', only):
        snapshot = base / 'snapshots' / record['sha256']
        if not snapshot.exists():
            snapshot.mkdir(parents=True)
            value = json.loads(content)
            for name, text in value['files'].items():
                path = snapshot / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(text.encode())
            (snapshot / 'artifact.json').write_bytes(content)
        folder = base / 'state' / record['id']
        folder.mkdir(parents=True, exist_ok=True)
        (folder / '1.json').write_text(json.dumps({
            'schema': 1, 'id': record['id'], 'generation': 1, 'enabled': True,
            'selected': {'source': 'local', 'allow_lua': True, 'sha256': record['sha256'], 'version': '1.0.0',
                         'kind': 'tool' if record.get('executable') else 'plugin'},
        }))


if __name__ == '__main__':
    seed(Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:])
