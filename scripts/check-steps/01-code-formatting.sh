# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 1 "Code formatting (treefmt)" run_01_code_formatting

run_01_code_formatting() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _tf_exit=0

  if $_has_args; then
    if $FORMAT_NIX; then
      treefmt "${_files[@]}" || _tf_exit=$?
    else
      treefmt --fail-on-change "${_files[@]}" || _tf_exit=$?
    fi
  else
    if $FORMAT_NIX; then
      treefmt || _tf_exit=$?
    else
      treefmt --fail-on-change || _tf_exit=$?
    fi
  fi

  if [ $_tf_exit -eq 0 ]; then
    say "formatting OK."
  elif [ $_tf_exit -eq 1 ]; then
    error "formatting issues found (run 'treefmt' to fix)."
  else
    error "treefmt failed with exit code $_tf_exit"
  fi

  return $_tf_exit
}
