# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "code-formatting" 1 "Code formatting (treefmt)" run_01_code_formatting

run_01_code_formatting() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _tf_exit=0

  if $_has_args; then
    treefmt "${_files[@]}" || _tf_exit=$?
  else
    treefmt || _tf_exit=$?
  fi

  if [ $_tf_exit -eq 0 ]; then
    say "formatting OK."
  else
    error "treefmt failed with exit code $_tf_exit"
  fi

  return $_tf_exit
}
