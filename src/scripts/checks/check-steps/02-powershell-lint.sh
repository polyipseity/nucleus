# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "powershell-lint" "PowerShell syntax" run_powershell_lint posix any none

run_powershell_lint() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  local _ps_exit=0

  local -n _ps1_files="${ctx[PS1_FILES]}"
  cd "$_repo_root" || return 1

  # A scoped run with no .ps1 in scope checks nothing. Without this the analyzer
  # falls back to `git ls-files` and lints every PowerShell file in the repo,
  # which is the inverse of the scoped contract.
  if [ "$_has_args" = true ] && [ "${#_ps1_files[@]}" -eq 0 ]; then
    say "0 PowerShell files in scope — syntax check not run."
    return 0
  fi

  bash scripts/check.sh pwsh ${_ps1_files[@]+"${_ps1_files[@]}"} || _ps_exit=$?

  return $_ps_exit
}
