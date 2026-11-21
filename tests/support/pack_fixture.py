"""Install generated resource fixtures into an isolated test data directory."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from pack_assets import assets
from resource_bundle import encoded


def build_fixture(root, base, only, verified_tools):
    for _, content, record in assets(root, '1.0.0', 'https://example.invalid/nvim-zh', only):
        value = json.loads(content)
        if record.get('tool') and not verified_tools:
            value['manifest'].pop('tool')
            content = encoded(value)
            record['sha256'] = hashlib.sha256(content).hexdigest()
        snapshot = base / 'snapshots' / record['sha256']
        if not snapshot.exists():
            snapshot.mkdir(parents=True)
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


def fixture_key(root, only, verified_tools):
    paths = [root / "tools" / f"{name}.py" for name in
             ("pack_assets", "adapter_manifest", "catalog_tool", "resource_bundle", "toolchain_catalog", "diagnostic_inventory")]
    for name in ("manifests", "translations/adapters", "translations/po/zh_CN", "translations/glossary", "translations/toolchain", "doc"):
        paths.extend(path for path in (root / name).rglob("*") if path.is_file())
    digest = hashlib.sha256(f"SDK1:{only}:{verified_tools}".encode())
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def seed(root, data, only=None, *, verified_tools=False):
    root = root.resolve()
    base = data / os.environ.get("NVIM_APPNAME", "nvim") / "nvim-zh/packs"
    cache = os.environ.get("NVIM_ZH_TEST_PACK_CACHE")
    if not cache:
        build_fixture(root, base, only, verified_tools)
        return
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    ready = cache / fixture_key(root, only, verified_tools)
    if not ready.is_dir():
        with tempfile.TemporaryDirectory(dir=cache) as stage:
            built = Path(stage) / "packs"
            build_fixture(root, built, only, verified_tools)
            try:
                built.rename(ready)
            except OSError:
                if not ready.is_dir():
                    raise
    shutil.copytree(ready, base, dirs_exist_ok=True)


if __name__ == '__main__':
    seed(Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:])
