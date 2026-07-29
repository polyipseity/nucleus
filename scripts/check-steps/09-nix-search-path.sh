# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 9 "Nix search path tests" run_09_nix_search_path

run_09_nix_search_path() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _nspt_exit=0

  echo "--- test output ---"
  bash tests/scripts/nix-search-path-tests.sh || _nspt_exit=$?
  echo "--- end test output ---"

  return $_nspt_exit
}
