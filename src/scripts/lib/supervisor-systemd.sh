# shellcheck shell=bash
# Supervisor backend for systemd (NixOS).
# Implements supervisor_* functions for the service-watchdog core runner.
#
# Usage:
#   . "$SCRIPT_DIR/../lib/supervisor-systemd.sh"

[ -n "${_NUCLEUS_SUPERVISOR_SYSTEMD_SOURCED-}" ] && return
_NUCLEUS_SUPERVISOR_SYSTEMD_SOURCED=1

_SUPERVISOR_SYSTEMD_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SUPERVISOR_SYSTEMD_DIR/lib.sh"

# supervisor_enabled — is the systemd unit enabled?
# Args: $1 — unit name; $2 — scope ("user" or "system").
supervisor_enabled() {
  local unit="$1" scope="$2"
  local cmd=(systemctl)
  [ "$scope" = "system" ] || cmd+=(--user)
  "${cmd[@]}" is-enabled "$unit" >/dev/null 2>&1
}

# supervisor_live — is the unit currently active?
# Args: $1 — systemctl status output (piped).
supervisor_live() {
  local status_out="$1"
  case "$status_out" in
  *"Active: active"*) return 0 ;;
  esac
  return 1
}

# supervisor_counter — extract NRestarts from systemctl show.
# Args: $1 — unit name; $2 — scope.
supervisor_counter() {
  local unit="$1" scope="$2"
  local cmd=(systemctl)
  [ "$scope" = "system" ] || cmd+=(--user)
  "${cmd[@]}" show "$unit" -p NRestarts --value 2>/dev/null || printf '0'
}

# supervisor_last_exit — extract the last exit code from systemctl show.
# Args: $1 — unit name; $2 — scope.
supervisor_last_exit() {
  local unit="$1" scope="$2"
  local cmd=(systemctl)
  [ "$scope" = "system" ] || cmd+=(--user)
  "${cmd[@]}" show "$unit" -p ExecMainStatus --value 2>/dev/null || printf '0'
}

# supervisor_start — start a systemd unit.
# Args: $1 — unit name; $2 — scope; $3 — unused (compat).
supervisor_start() {
  local unit="$1" scope="$2"
  local cmd=(systemctl)
  [ "$scope" = "system" ] || cmd+=(--user)
  "${cmd[@]}" start "$unit" 2>/dev/null
}

# supervisor_stop — stop a systemd unit.
# Args: $1 — unit name; $2 — scope; $3 — unused (compat).
supervisor_stop() {
  local unit="$1" scope="$2"
  local cmd=(systemctl)
  [ "$scope" = "system" ] || cmd+=(--user)
  # check-suppress:suppression_doc: stop may fail if the unit is already stopped
  "${cmd[@]}" stop "$unit" 2>/dev/null || true
}

# supervisor_repair — reset-failed + restart for a wedged unit.
# Args: $1 — unit name; $2 — scope; $3 — unused (compat).
supervisor_repair() {
  local unit="$1" scope="$2"
  local cmd=(systemctl)
  [ "$scope" = "system" ] || cmd+=(--user)
  # check-suppress:suppression_doc: reset-failed may fail if the unit is not in failed state
  "${cmd[@]}" reset-failed "$unit" 2>/dev/null || true
  "${cmd[@]}" start "$unit" 2>/dev/null
}

# supervisor_kind — return the supervisor kind identifier.
supervisor_kind() {
  printf 'systemd'
}
