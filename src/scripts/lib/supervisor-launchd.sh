# shellcheck shell=bash
# Supervisor backend for launchd (macOS).
# Implements supervisor_* functions for the service-watchdog core runner.
#
# Usage:
#   . "$SCRIPT_DIR/../lib/supervisor-launchd.sh"

[ -n "${_NUCLEUS_SUPERVISOR_LAUNCHD_SOURCED-}" ] && return
_NUCLEUS_SUPERVISOR_LAUNCHD_SOURCED=1

_SUPERVISOR_LAUNCHD_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SUPERVISOR_LAUNCHD_DIR/lib.sh"

# supervisor_enabled — is the launchd job loaded?
# Args: $1 — target (gui/<uid>/<label> or system/<label>).
supervisor_enabled() {
  local target="$1"
  launchctl print "$target" >/dev/null 2>&1
}

# supervisor_live — is the job currently running?
# Args: $1 — launchctl print output (piped).
supervisor_live() {
  local print_out="$1"
  case "$print_out" in
  *"state = running"*) return 0 ;;
  esac
  return 1
}

# supervisor_counter — extract the runs counter from launchctl print output.
# Args: $1 — launchctl print output.
supervisor_counter() {
  local print_out="$1"
  printf '%s' "$print_out" | awk '/runs =/{print $3; exit}'
}

# supervisor_last_exit — extract the last exit code from launchctl print output.
# Args: $1 — launchctl print output.
supervisor_last_exit() {
  local print_out="$1"
  printf '%s' "$print_out" | awk '/last exit code/{print $4; exit}'
}

# supervisor_start — bootstrap a launchd job.
# Args: $1 — target; $2 — plist path; $3 — sudo prefix (optional).
supervisor_start() {
  local target="$1" plist="$2" sudo_prefix="${3:-}"
  local domain
  domain="$(launchctl_bootstrap_domain "$(printf '%s' "$target" | cut -d/ -f1)" "$(printf '%s' "$target" | cut -d/ -f2)")"
  ${sudo_prefix} launchctl bootstrap "$domain" "$plist" 2>/dev/null
}

# supervisor_stop — bootout a launchd job.
# Args: $1 — target; $2 — sudo prefix (optional).
supervisor_stop() {
  local target="$1" sudo_prefix="${3:-}"
  # check-suppress:suppression_doc: bootout may fail if the job is already unloaded
  ${sudo_prefix} launchctl bootout "$target" 2>/dev/null || true
}

# supervisor_repair — bootout + bootstrap for a wedged job (EX_CONFIG 78).
# Args: $1 — target; $2 — plist path; $3 — sudo prefix (optional).
supervisor_repair() {
  local target="$1" plist="$2" sudo_prefix="${3:-}"
  # check-suppress:suppression_doc: bootout may fail if the job is already unloaded
  ${sudo_prefix} launchctl bootout "$target" 2>/dev/null || true
  sleep 1
  supervisor_start "$target" "$plist" "$sudo_prefix"
}

# supervisor_kind — return the supervisor kind identifier.
supervisor_kind() {
  printf 'launchd'
}
