#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/env.sh"
: "${NVIM_ZH_ADAPTER_SOURCE_ROOT:?set NVIM_ZH_ADAPTER_SOURCE_ROOT to the fixed source store}"
case_env
result="${NVIM_ZH_ADAPTER_REPORT:-$NVIM_ZH_TMP/upstream-adapters.json}"
if ! "$PYTHON" "$ROOT/tools/adapter_tool.py" test all --upstream \
  --source-root "$NVIM_ZH_ADAPTER_SOURCE_ROOT" --json > "$result"; then
  "$PYTHON" -c 'import json, sys; data = json.load(open(sys.argv[1])); print(data.get("error", "Adapter test failed"))' "$result" >&2
  exit 1
fi
printf 'UPSTREAM_RESULT=PASS (fixed source contracts and complete adapter TUI scenarios)\n'
