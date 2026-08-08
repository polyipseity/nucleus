# shellcheck shell=bash
# shellcheck source=../check-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "host-platform-audit" 27 "Host platform audit" run_27_host_platform_audit

run_27_host_platform_audit() {
  local _has_args="$1" _repo_root="$2"; shift 2
  if bash "$_repo_root/src/scripts/checks/host-platform-audit.sh" "$_repo_root"; then
    say "host platform audit passed"
    return 0
  fi
  error "host platform audit failed — see VIOLATION lines above"
  return 1
}
