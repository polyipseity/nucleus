# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step 3 "Nucleus apps smoke tests" run_03_nucleus_apps_smoke

run_03_nucleus_apps_smoke() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _exit_code=0

  say "--- test output ---"
  if [ "$quiet_mode" = true ]; then
    bash tests/scripts/nucleus-apps-smoke-tests.sh >/dev/null || _exit_code=1
  else
    bash tests/scripts/nucleus-apps-smoke-tests.sh || _exit_code=1
  fi
  say "--- end test output ---"

  return "$_exit_code"
}
