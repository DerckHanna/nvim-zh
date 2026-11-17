#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
NVIM_BIN=${NVIM_BIN:-nvim}
python=${PYTHON:-python3}
export NVIM_ZH_ROOT=$ROOT
export PYTHONDONTWRITEBYTECODE=1
# Neovim falls back to writing ./nvim.log when its state directory is not
# writable (e.g. read-only home in a sandbox). Give every phase a private
# state dir so a release-blocking log can never appear in the package.
state=$(mktemp -d "${TMPDIR:-/tmp}/dsh-nvim-zh-state-$(date +%Y%m%dT%H%M%S)-XXXXXX")
trap 'rm -rf -- "$state"' EXIT
export XDG_STATE_HOME=$state
for spec in "$HERE"/*_spec.lua; do
  printf 'PHASE8_SPEC=%s\n' "$(basename "$spec")"
  "$NVIM_BIN" --headless -u NONE --cmd "set runtimepath^=$ROOT" --cmd "runtime! plugin/nvim-zh.lua" -l "$spec" 2>&1
done
PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT="$ROOT" "$python" "$HERE/test_help_catalog.py"
# Per-document coverage for the *whole* runtime corpus: every doc/*.txt must
# carry an explicit complete/partial/excluded/not_started status, and the
# inventory must regenerate byte-identically.
PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT="$ROOT" NVIM_BIN="$NVIM_BIN" "$python" "$HERE/test_help_inventory.py"
# translations/glossary/zh_CN.toml applies to help prose as well: a `preserve`
# term must never appear in its forbidden Chinese form in doc/*.cnx.
PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT="$ROOT" "$python" "$HERE/test_help_terminology.py"
# The Lua spec stops at the first parity break, which is fine as a contract but
# unhelpful while translating a 2000-line document. Run the exhaustive checker
# too so a regression reports every broken tag, block and link at once.
PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT="$ROOT" NVIM_BIN="$NVIM_BIN" VIMRUNTIME="$("$NVIM_BIN" --headless -u NONE -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'qa!' 2>/dev/null)" \
  "$python" "$HERE/check_help_parity.py"
# The parity checker compares against the runtime the manifest pins; a different
# runtime must skip with HELP_PARITY=SKIP rather than report version drift.
PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT="$ROOT" "$python" "$HERE/test_help_parity_skip.py"
printf 'PHASE8_RESULT=PASS\n'
