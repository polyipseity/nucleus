# shellcheck shell=bash
# Supervisor backend for systemd (NixOS), one half of the uniform supervisor_*
# contract consumed by service-watchdog.sh. systemctl addresses a unit by name, so
# operations take the unit id, never a path, and the declared unit path is resolved
# for diagnostics only.

[ -n "${_NUCLEUS_SUPERVISOR_SYSTEMD_SOURCED-}" ] && return
_NUCLEUS_SUPERVISOR_SYSTEMD_SOURCED=1

_SUPERVISOR_SYSTEMD_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SUPERVISOR_SYSTEMD_DIR/lib.sh"

_systemd_scope_args() {
  if [ "${1:-user}" = "system" ]; then
    printf '%s' "--system"
  else
    printf '%s' "--user"
  fi
}

# Args: $1 unit name, $2 declared path (optional).
supervisor_unit_path() {
  local unit="$1" declared="${2:-}"
  [ -n "$declared" ] || return 0
  supervisor_resolve_unit_path "$declared" "$unit"
}

# 0 when the unit exists and the user has not disabled it.
# Args: $1 unit, $2 declared unit path (unused, accepted so every backend shares one
#       arity), $3 scope.
# WHY: the contract reports "exists and is allowed to start", so ABSENT counts as
#   not enabled and the watchdog reports a declared-but-uninstalled unit as not
#   loaded instead of starting one that does not exist. "static", "indirect" and
#   inactive are not absent: a unit can exist without install info, and inactive is
#   the state Rule 4 repairs. An EMPTY reply is not a state either, so it fails
#   closed: reading the exit code failed closed on the same condition, and parsing
#   the output must not turn an unreadable state into permission to start.
supervisor_enabled() {
  local unit="$1" scope="${3:-user}" state
  # check-suppress:suppression_doc: is-enabled fails for a unit without install info; that is not a user disable
  state="$(systemctl "$(_systemd_scope_args "$scope")" is-enabled "$unit" 2>/dev/null || true)"
  [ -n "$state" ] || return 1
  [ "$state" != "not-found" ] && [ "$state" != "disabled" ] && [ "$state" != "masked" ]
}

# Args: $1 output of `systemctl status`.
supervisor_live() {
  local status_out="$1"
  case "$status_out" in
  *"Active: active"*) return 0 ;;
  esac
  return 1
}

# The unit's run token, a value that changes on every new run. systemd reports a
# monotonic restart count; the watchdog only compares for inequality, so one name
# covers the process identity and timestamps the Windows backend feeds it.
# Args: $1 unit, $2 scope.
supervisor_generation() {
  local unit="$1" scope="${2:-user}" count
  # check-suppress:suppression_doc: a unit with no manager state has no counter; zero restarts is the correct reading
  count="$(systemctl "$(_systemd_scope_args "$scope")" show "$unit" -p NRestarts --value 2>/dev/null || true)"
  printf '%s' "${count:-0}"
}

# Args: $1 unit, $2 scope.
supervisor_last_exit() {
  local unit="$1" scope="${2:-user}" code
  # check-suppress:suppression_doc: a unit with no manager state has no recorded exit; zero is the correct reading
  code="$(systemctl "$(_systemd_scope_args "$scope")" show "$unit" -p ExecMainStatus --value 2>/dev/null || true)"
  printf '%s' "${code:-0}"
}

# Args: $1 unit, $2 declared unit path (unused), $3 scope.
supervisor_start() {
  local unit="$1" scope="${3:-user}"
  # check-suppress:suppression_doc: start fails when the unit is already active, which is the desired end state
  systemctl "$(_systemd_scope_args "$scope")" start "$unit" 2>/dev/null || true
}

# Args: $1 unit, $2 scope.
supervisor_stop() {
  local unit="$1" scope="${2:-user}"
  # check-suppress:suppression_doc: stop fails when the unit is already inactive, which is the desired end state
  systemctl "$(_systemd_scope_args "$scope")" stop "$unit" 2>/dev/null || true
}

# Args: $1 unit, $2 declared unit path (unused), $3 scope.
supervisor_repair() {
  local unit="$1" scope="${3:-user}"
  # check-suppress:suppression_doc: restart fails when the unit is not loadable; the next tick retries
  systemctl "$(_systemd_scope_args "$scope")" restart "$unit" 2>/dev/null || true
}

supervisor_kind() {
  printf 'systemd'
}
