#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
NVIM_BIN=${NVIM_BIN:-nvim}
export NVIM_ZH_ROOT=$ROOT
# Neovim falls back to writing ./nvim.log (0.12) or ./.nvimlog (0.10/0.11) into
# the current directory when its state directory is not writable, which is the
# read-only-$HOME sandbox this project is developed in. Every phase*/run.sh
# already gives Neovim a private state dir; this entry point needs the same
# guard, otherwise `make test-foundation` leaves a release-blocking artefact in
# the repository root.
state=$(mktemp -d "${TMPDIR:-/tmp}/dsh-nvim-zh-state-$(date +%Y%m%dT%H%M%S)-XXXXXX")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dsh-nvim-zh-foundation-$(date +%Y%m%dT%H%M%S)-XXXXXX")
trap 'rm -rf -- "$state" "$tmp"' EXIT
export XDG_STATE_HOME=$state
for spec in 01_setup_spec.lua 02_commands_spec.lua 03_native_health_spec.lua; do
  echo "FOUNDATION_SPEC=$spec"
  "$NVIM_BIN" --headless -u NONE --cmd "set runtimepath^=$ROOT" --cmd 'runtime! plugin/nvim-zh.lua' -l "$ROOT/tests/phase1/$spec" 2>&1
done
NVIM_ZH_TMP="$tmp" "$NVIM_BIN" --headless -u NONE -l "$ROOT/tests/phase0/e2_help.lua" 2>&1
echo 'FOUNDATION_RESULT=PASS engine=phase2 setup_commands_native_health=pass help=cnx_tags-cn_fallback'
