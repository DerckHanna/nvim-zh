#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/env.sh"
run_suite e2e
printf 'E2E_RESULT=PASS\n'
