#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/env.sh"
# Explicit upstream entry: a missing checkout is a failure, never a skip.
for source_env in NVIM_ZH_TEST_WHICH_KEY NVIM_ZH_TEST_TELESCOPE NVIM_ZH_TEST_PLENARY NVIM_ZH_TEST_LAZY NVIM_ZH_TEST_NVIM_TREE NVIM_ZH_TEST_NVIM_CMP; do
  if [[ -z ${!source_env:-} || ! -d ${!source_env} ]]; then
    printf 'UPSTREAM=FAIL missing fixed source: %s\n' "$source_env" >&2
    exit 1
  fi
done
run_python "$ROOT/tests/upstream/test_sources.py"
run_python "$ROOT/tests/upstream/cmp_seam.py"
while IFS= read -r spec; do run_lua "$spec"; done < <(find "$ROOT/tests/upstream" -type f -name '*_spec.lua' | sort)
printf 'UPSTREAM_RESULT=PASS\n'
