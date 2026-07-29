# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 7 "Shell script validation tests" run_07_shell_validation

run_07_shell_validation() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _svt_exit=0
  local _svt_tmpdir
  _svt_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _svt_exit=1; }

  {
    echo "--- test output ---"
    bash tests/scripts/script-validation-tests.sh
    echo $? > "$_svt_tmpdir/svt.exit"
    echo "--- end test output ---"
  } &
  {
    echo "--- test output ---"
    bash tests/scripts/check-output-format-tests.sh
    echo $? > "$_svt_tmpdir/cot.exit"
    echo "--- end test output ---"
  } &
  wait

  local _ssvt_rc _cot_rc
  _ssvt_rc=$(cat "$_svt_tmpdir/svt.exit" 2>/dev/null || echo 1)
  _cot_rc=$(cat "$_svt_tmpdir/cot.exit" 2>/dev/null || echo 1)
  [ "$_ssvt_rc" -ne 0 ] && _svt_exit=1
  [ "$_cot_rc" -ne 0 ] && _svt_exit=1
  rm -rf -- "$_svt_tmpdir"

  return $_svt_exit
}
