#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "windows-pester" "Windows Pester tests" run_windows_pester

run_windows_pester() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  say "skipping (Windows Pester tests are pwsh-only)."
  return 2
}
