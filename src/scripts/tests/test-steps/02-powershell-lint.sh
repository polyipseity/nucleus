#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "powershell-lint-test" 2 "PowerShell lint smoke" run_02_powershell_lint

run_02_powershell_lint() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _exit_code=0

  say "--- check-pwsh smoke tests (PSSA skipped via -SkipStep; full lint runs in check step 2) ---"
  bash tests/scripts/check-pwsh-tests.sh || _exit_code=1
  say "--- end check-pwsh smoke tests ---"

  return "$_exit_code"
}
