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
  bash scripts/check.sh pwsh || _ps_exit=$?

  return $_ps_exit
}
