# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step 2 "PowerShell lint" run_02_powershell_lint

run_02_powershell_lint() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _exit_code=0

  say "--- test output ---"
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -Settings scripts/PSScriptAnalyzerSettings.test.psd1 || _exit_code=1
  bash tests/scripts/check-pwsh-tests.sh || _exit_code=1
  bash tests/scripts/test-output-format-tests.sh || _exit_code=1
  say "--- end test output ---"

  return "$_exit_code"
}
