#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/env.sh"
run_suite contract
printf 'CONTRACT_RESULT=PASS\n'
