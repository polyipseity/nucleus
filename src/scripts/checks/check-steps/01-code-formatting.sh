# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "code-formatting" "Code formatting and linting" run_code_formatting posix any none

run_code_formatting() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  local -n _pkr_files="${ctx[PKR_FILES]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _exit=0

  if $_has_args; then
    treefmt "${_files[@]}" || _exit=$?
  else
    treefmt || _exit=$?
  fi

  if [ $_exit -ne 0 ]; then
    error "treefmt failed with exit code $_exit"
    return $_exit
  fi
  say "treefmt OK."

  local _pkr_exit=0
  if [ "${#_pkr_files[@]}" -gt 0 ]; then
    bash scripts/check.sh packer --validate-only "${_pkr_files[@]}" || _pkr_exit=$?
  elif ! $_has_args; then
    bash scripts/check.sh packer --validate-only || _pkr_exit=$?
  else
    say "0 Packer templates in scope — check-packer not run."
  fi

  if [ $_pkr_exit -eq 0 ]; then
    say "Packer template validation passed."
  fi

  return $_pkr_exit
}
