#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NVIM_BIN=${NVIM_BIN:-nvim}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsh-nvim-zh-phase0-$(date +%Y%m%d-%H%M%S).XXXXXX")
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT
export NVIM_ZH_TMP=$TMP_ROOT
export NVIM_BIN
# Neovim falls back to writing ./nvim.log when its state directory is not
# writable (e.g. read-only home in a sandbox), which would leave a
# release-blocking artifact in the package.
export XDG_STATE_HOME=$TMP_ROOT/state
mkdir -p "$XDG_STATE_HOME"

printf 'PHASE0_NVIM=%s\n' "$(command -v "$NVIM_BIN")"
"$NVIM_BIN" --version | head -n 3
bash "$HERE/e1_native.sh"
for case_name in e2_help e3_public_ui e5_diagnostic; do
  "$NVIM_BIN" --headless -u NONE -l "$HERE/$case_name.lua" 2>&1
 done
# nvim_echo intentionally exercises real output. Keep raw evidence in the temp
# directory and expose only the measurements and assertions.
"$NVIM_BIN" --headless -u NONE -l "$HERE/e4_ui_attach.lua" >"$TMP_ROOT/e4.raw" 2>&1
cat "$TMP_ROOT/e4.result"
printf 'PHASE0_RESULT=PASS\n'
