#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "nucleus-apps-smoke" 3 "Nucleus apps smoke tests" run_03_nucleus_apps_smoke

run_03_nucleus_apps_smoke() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _exit_code=0

  say "--- test output ---"
  # WHY: the smoke suite runs `nix build --no-link --json` for all nucleus
  # apps; serialize it with the other nix steps (01/04) to avoid SQLite
  # eval-cache contention.
  if [ "$quiet_mode" = true ]; then
    nucleus_nix_locked bash tests/scripts/nucleus-apps-smoke-tests.sh >/dev/null || _exit_code=1
  else
    nucleus_nix_locked bash tests/scripts/nucleus-apps-smoke-tests.sh || _exit_code=1
  fi
  say "--- end test output ---"

  return "$_exit_code"
}
