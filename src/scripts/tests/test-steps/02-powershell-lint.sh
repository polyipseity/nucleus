#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "powershell-lint-test" 2 "PowerShell lint (PSSA)" run_02_powershell_lint

run_02_powershell_lint() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _exit_code=0

  say "--- PSScriptAnalyzer lint (syntax runs in check step 2) ---"
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 \
    -SkipStep Syntax \
    -Settings scripts/PSScriptAnalyzerSettings.test.psd1 || _exit_code=1
  say "--- end PSScriptAnalyzer lint ---"

  return "$_exit_code"
}
