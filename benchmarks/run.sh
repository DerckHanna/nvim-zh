#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../tests/run/lib/env.sh"
run_lua "$ROOT/benchmarks/ui_attach.lua" > "$TEST_ROOT/ui-attach.raw" 2>&1
cat "$NVIM_ZH_TMP/e4.result"
