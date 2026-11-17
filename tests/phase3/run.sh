#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
NVIM_BIN=${NVIM_BIN:-nvim}
export NVIM_ZH_ROOT=$ROOT
export PYTHONDONTWRITEBYTECODE=1
# Neovim falls back to writing ./nvim.log when its state directory is not
# writable (e.g. read-only home in a sandbox). Give every phase a private
# state dir so a release-blocking log can never appear in the package.
state=$(mktemp -d "${TMPDIR:-/tmp}/dsh-nvim-zh-state-$(date +%Y%m%dT%H%M%S)-XXXXXX")
trap 'rm -rf -- "$state"' EXIT
export XDG_STATE_HOME=$state
for spec in "$HERE"/*_spec.lua; do
  printf 'PHASE3_SPEC=%s\n' "$(basename "$spec")"
  "$NVIM_BIN" --headless -u NONE --cmd "set runtimepath^=$ROOT" --cmd "runtime! plugin/nvim-zh.lua" -l "$spec" 2>&1
done
printf 'PHASE3_RESULT=PASS\n'
