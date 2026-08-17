# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"
# shellcheck source=../lockfile-enforcement-lib.sh
# (provides _lfe_check_*, _lfe_warn_suggestions, verify_installed_versions)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lockfile-enforcement-lib.sh"

register_step "lockfile-enforcement" "Lockfile version enforcement" run_lockfile_enforcement

run_lockfile_enforcement() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  cd "$_repo_root" || return 1

  # Skip when scoped to files outside this step's scope (no lockfile JSON files).
  if $_has_args; then
    local _f _has_lf=0
    for _f in "$@"; do
      case "$_f" in *lockfile*.json) _has_lf=1; break ;; esac
    done
    if [ "$_has_lf" -eq 0 ]; then
      skip_step "$(step_number)" "Lockfile version enforcement" "no lockfile files to check"
      return 2
    fi
  fi

  local _lockfile="src/lockfiles/lockfile.json"
  if [ ! -f "$_lockfile" ]; then
    skip_step "$(step_number)" "Lockfile version enforcement" "no lockfile present"
    return 2
  fi

  local _jq
  _jq="$(command -v jq || true)"
  if [ -z "$_jq" ]; then
    error "jq not found; cannot enforce lockfile versions"
    return 1
  fi

  local _lf_data _failures
  # check-suppress:suppression_doc: malformed lockfile is fatal for enforcement -- reported as error below.
  _lf_data="$(cat "$_lockfile" 2>/dev/null)" || true
  if [ -z "$_lf_data" ]; then
    error "lockfile.json could not be read"
    return 1
  fi

  # Pinned root sections applicable on POSIX (Windows-inapplicable sections
  # are skipped by their own tool guards in the shared probe library).
  _lfe_run_core "$_lf_data" "$_jq"
  _failures=$?
  if [ "$_failures" -gt 0 ]; then
    error "lockfile enforcement found $_failures pinned section(s) with version drift"
    return 1
  fi
  say "lockfile enforcement: all applicable pinned sections match"
  return 0
}
