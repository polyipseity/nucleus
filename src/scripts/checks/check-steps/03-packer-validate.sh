# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 3 "Packer template validation" run_03_packer_validate

run_03_packer_validate() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _pkr_exit=0

  if [ "${#PKR_FILES[@]}" -gt 0 ]; then
    bash scripts/check-packer.sh "${PKR_FILES[@]}" || _pkr_exit=$?
  elif ! $_has_args; then
    bash scripts/check-packer.sh || _pkr_exit=$?
  else
    say "skipping (no Packer templates to check)."
  fi

  return $_pkr_exit
}
