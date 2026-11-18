"""Native (core gettext) catalog contracts for nvim-zh.

The suite is offline: it validates the translation resource in
translations/native/ against manifests/native.json, exercises merge/render with a
synthetic upstream catalog, and (when gettext and a usable locale are present)
compiles an MO and probes it through a copied Neovim binary in a temporary
prefix. No system file, locale, or Neovim installation is modified.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
sys.path.insert(0, str(ROOT / 'tools'))
import native_catalog as nc  # noqa: E402

NVIM = os.environ.get('NVIM_BIN', 'nvim')


LOCALE_SOURCE = Path('/usr/share/i18n/locales/zh_CN')


def _runtime_for(binary: str | None) -> Path | None:
    """$VIMRUNTIME of the binary under test, so the probe never uses a foreign tree."""
    if binary is None:
        return None
    out = subprocess.run(
        [binary, '--headless', '-u', 'NONE', '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
        capture_output=True, text=True, timeout=60,
        env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', '/tmp')})
    value = Path(out.stdout.strip())
    return value if (value / 'doc').is_dir() else None


def _probe_prefix(tmp: Path, mo: Path, runtime: Path) -> tuple[Path, dict]:
    """A copied binary + temp locale + temp state dir, so nothing host-side moves."""
    prefix = tmp / 'prefix'
    (prefix / 'bin').mkdir(parents=True)
    mo_dir = prefix / 'share/locale/zh_CN.UTF-8/LC_MESSAGES'
    mo_dir.mkdir(parents=True)
    shutil.copy2(shutil.which(NVIM), prefix / 'bin/nvim')
    shutil.copy2(mo, mo_dir / 'nvim.mo')
    locale_dir = tmp / 'locale'
    locale_dir.mkdir()
    subprocess.run(['localedef', '-i', 'zh_CN', '-f', 'UTF-8', str(locale_dir / 'zh_CN.UTF-8')],
                   check=True, capture_output=True)
    state = tmp / 'state'
    (state / 'nvim/shada').mkdir(parents=True)
    # Not a msgpack file: reading it reports E576, and the failed rewrite on exit
    # reports E136.
    (state / 'nvim/shada/main.shada').write_bytes(b'garbage-not-msgpack-\x01\x02\x03')
    env = {**os.environ, 'VIMRUNTIME': str(runtime), 'LOCPATH': str(locale_dir),
           'LC_ALL': 'zh_CN.UTF-8', 'XDG_STATE_HOME': str(state)}
    return prefix / 'bin/nvim', env


def _run_probe(binary: Path, env: dict, args: list[str]) -> str:
    process = subprocess.run([str(binary), '--headless', '-u', 'NONE', *args],
                             capture_output=True, text=True, env=env, timeout=60)
    return process.stdout + process.stderr
