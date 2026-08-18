# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "powershell-lint" "PowerShell syntax" run_powershell_lint

run_powershell_lint() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _ps_exit=0

  local -n _ps1_files="${ctx[PS1_FILES]}"
  if [ "${#_ps1_files[@]}" -gt 0 ]; then
    local _ps_paths
    _ps_paths=$(printf "'%s'," "${_ps1_files[@]}")
    pwsh -NoLogo -NoProfile -NonInteractive -Command "& scripts/check-pwsh.ps1 -SkipStep PSSA -Scoped -Paths @(${_ps_paths%,})" || _ps_exit=$?
  elif ! $_has_args; then
    pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SkipStep PSSA || _ps_exit=$?
    if [ "$_ps_exit" -eq 0 ]; then
      pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh-naming.ps1 || _ps_exit=$?
    fi
  else
    say "skipping (no PowerShell scripts to check)."
    return 2
  fi

  return $_ps_exit
}
