#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/env.sh"
run_suite integration
case_env
bash "$ROOT/tests/integration/native/locale_probe.sh"
run_python "$ROOT/tools/help_parity.py"
if [[ -n ${NVIM_ZH_TEST_CLANGD:-} ]]; then
  run_python "$ROOT/tests/integration/clangd/real_smoke.py"
else
  echo 'REAL_CLANGD_SMOKE=SKIP set NVIM_ZH_TEST_CLANGD=/absolute/path/to/clangd'
fi
printf 'INTEGRATION_RESULT=PASS\n'
