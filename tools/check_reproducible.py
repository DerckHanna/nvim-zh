"""Rebuild PO-derived Lua, pinned native MO, and the complete resource payload."""
from pathlib import Path
import tempfile
import catalog_tool as ct
import native_catalog as nc
import resource_bundle as bundle

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='nvim-zh-repro-') as tmp:
    out = Path(tmp)
    ct.builtin_sources(root, optional=True)
    ct.build(root / 'translations/po/zh_CN', out / 'lua', root / 'translations/glossary/zh_CN.toml',
             ct.builtin_sources(root).values())
    def payload(folder):
        return {p.relative_to(folder).as_posix(): p.read_bytes() for p in folder.rglob('*') if p.is_file()}
    if payload(out / 'lua') != payload(root / 'lua/nvim-zh/catalogs/generated'):
        raise SystemExit('REPRODUCIBLE_BUILD=FAIL generated Lua differs')
    manifest = nc.load_manifest(root)
    nc.build(root, manifest, root / 'build/upstream/zh_CN.UTF-8.po', out / 'native',
             expect_sha=manifest['upstream']['sha256'])
    mo = Path('zh_CN.UTF-8/LC_MESSAGES/nvim.mo')
    if (out / 'native' / mo).read_bytes() != (root / 'build/native' / mo).read_bytes():
        raise SystemExit('REPRODUCIBLE_BUILD=FAIL native MO differs')
    first, second = bundle.contents(root), bundle.contents(root)
    if first != second or first != payload(root / 'resources'):
        raise SystemExit('REPRODUCIBLE_BUILD=FAIL resource payload differs')
print('REPRODUCIBLE_BUILD=PASS generated_lua native_mo complete_resources')
