# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "powershell-lint" 2 "PowerShell lint" run_02_powershell_lint

run_02_powershell_lint() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _ps_exit=0

  if [ "${#PS1_FILES[@]}" -gt 0 ]; then
    local _ps_paths
    _ps_paths=$(printf "'%s'," "${PS1_FILES[@]}")
    pwsh -NoLogo -NoProfile -NonInteractive -Command "& scripts/check-pwsh.ps1 -Settings scripts/PSScriptAnalyzerSettings.check.psd1 -Scoped -Paths @(${_ps_paths%,})" || _ps_exit=$?
  elif ! $_has_args; then
    pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -Settings scripts/PSScriptAnalyzerSettings.check.psd1 || _ps_exit=$?
    if [ "$_ps_exit" -eq 0 ]; then
      pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh-naming.ps1 || _ps_exit=$?
    fi
  else
    say "skipping (no PowerShell scripts to check)."
    return 2
  fi

  return $_ps_exit
}
