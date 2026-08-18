#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "powershell-lint-test" "PowerShell lint (PSSA)" run_powershell_lint

run_powershell_lint() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _exit_code=0

  say "--- PSScriptAnalyzer lint (syntax runs in check step 2) ---"
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 \
    -SkipStep Syntax \
    -Settings scripts/PSScriptAnalyzerSettings.test.psd1 || _exit_code=1
  say "--- end PSScriptAnalyzer lint ---"

  return "$_exit_code"
}
