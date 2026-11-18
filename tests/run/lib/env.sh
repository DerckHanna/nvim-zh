#!/usr/bin/env bash
# Shared environment for every local/CI entry point. Source from a runner.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
NVIM_BIN=${NVIM_BIN:-nvim}
PYTHON=${PYTHON:-python3}
export NVIM_BIN PYTHON NVIM_ZH_ROOT=$ROOT PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$ROOT/tools:$ROOT/tests/support:$ROOT/tests/tools${PYTHONPATH:+:$PYTHONPATH}"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nvim-zh-tests-XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# A fresh case directory also prevents one spec from leaving JSON/config/state
# for the next spec. Python subprocesses inherit the same isolation.
case_env() {
  local case_root
  case_root=$(mktemp -d "$TEST_ROOT/case-XXXXXX")
  export XDG_STATE_HOME=$case_root/state
  export XDG_DATA_HOME=$case_root/data
  export XDG_CONFIG_HOME=$case_root/config
  export XDG_CACHE_HOME=$case_root/cache
  export XDG_RUNTIME_DIR=$case_root/runtime
  export NVIM_LOG_FILE=$case_root/nvim.log
  export TMPDIR=$case_root/tmp NVIM_ZH_TMP=$case_root/tmp
  mkdir -p "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR"
  chmod 700 "$XDG_RUNTIME_DIR"
}
run_lua() {
  case_env
  printf 'LUA_SPEC=%s\n' "${1#"$ROOT/"}"
  "$NVIM_BIN" --headless -u NONE -i NONE -n --cmd "set runtimepath^=$ROOT" --cmd 'runtime plugin/nvim-zh.lua' -l "$1"
}
run_python() {
  case_env
  printf 'PYTHON_SPEC=%s\n' "${1#"$ROOT/"}"
  "$PYTHON" "$1"
}
run_suite() {
  local suite=$1 spec
  while IFS= read -r spec; do run_lua "$spec"; done < <(find "$ROOT/tests/$suite" -type f -name '*_spec.lua' | sort)
  while IFS= read -r spec; do run_python "$spec"; done < <(find "$ROOT/tests/$suite" -type f -name 'test_*.py' | sort)
}
case_env
