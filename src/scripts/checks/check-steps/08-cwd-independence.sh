# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "cwd-independence" 8 "CWD-independence tests" run_08_cwd_independence

run_08_cwd_independence() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _cit_exit=0

  echo "--- test output ---"
  bash tests/scripts/cwd-independence-tests.sh || _cit_exit=$?
  echo "--- end test output ---"

  return $_cit_exit
}
