#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/env.sh"
run_suite tools
printf 'TOOLS_RESULT=PASS\n'
