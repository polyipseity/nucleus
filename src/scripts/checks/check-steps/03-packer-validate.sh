# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "packer-validate" 3 "Packer template validation" run_03_packer_validate

run_03_packer_validate() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _pkr_exit=0

  if [ "${#PKR_FILES[@]}" -gt 0 ]; then
    bash scripts/check-packer.sh "${PKR_FILES[@]}" || _pkr_exit=$?
  elif ! $_has_args; then
    bash scripts/check-packer.sh || _pkr_exit=$?
  else
    say "skipping (no Packer templates to check)."
    return 2
  fi

  return $_pkr_exit
}
