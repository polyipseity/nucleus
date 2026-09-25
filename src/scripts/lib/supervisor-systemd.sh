# shellcheck shell=bash
# Supervisor backend for systemd (NixOS).
# Implements the uniform supervisor_* contract consumed by service-watchdog.sh.
#
# Contract (identical arity on every backend):
#   supervisor_unit_path <unit> [declared path]        — resolve the unit file path
#   supervisor_enabled   <unit> [unit path] [scope]    — 0 when it exists and is not disabled
#   supervisor_live      <probe output>                — 0 when the unit is active
#   supervisor_generation <unit> [scope]               — run token, changes per run
#   supervisor_last_exit <unit> [scope]                — last exit status
#   supervisor_start     <unit> [unit path] [scope]    — start
#   supervisor_stop      <unit> [scope]                — stop
#   supervisor_repair    <unit> [unit path] [scope]    — restart a wedged unit
#   supervisor_kind                                    — backend identifier
#
# systemctl addresses a unit by name, so operations take the unit id — never a
# path. The declared unit path is resolved for diagnostics only.
#
# Usage:
#   . "$SCRIPT_DIR/../lib/supervisor-systemd.sh"

[ -n "${_NUCLEUS_SUPERVISOR_SYSTEMD_SOURCED-}" ] && return
_NUCLEUS_SUPERVISOR_SYSTEMD_SOURCED=1

_SUPERVISOR_SYSTEMD_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SUPERVISOR_SYSTEMD_DIR/lib.sh"

# _systemd_scope_args — systemctl arguments selecting the unit's manager.
_systemd_scope_args() {
  if [ "${1:-user}" = "system" ]; then
    printf '%s' "--system"
  else
    printf '%s' "--user"
  fi
}

# supervisor_unit_path — resolve the unit file path for a unit.
# Args: $1 — unit name; $2 — declared path (optional).
supervisor_unit_path() {
  local unit="$1" declared="${2:-}"
  [ -n "$declared" ] || return 0
  supervisor_resolve_unit_path "$declared" "$unit"
}

# supervisor_enabled — 0 when the unit exists and the user has not disabled it.
# WHY: this is the shared supervisor contract, and the Windows adapters spell it
#   out — Supervisor-Enabled reports "exists and is allowed to start". Rule 1
#   therefore covers ABSENT as well as disabled, which is what lets the watchdog
#   report a declared-but-uninstalled unit as not-loaded instead of trying to
#   start a unit that does not exist. "static" and "indirect" are NOT absent: a
#   unit can exist without install info, which is not a user disable. Inactive is
#   likewise not absent — it is the state revival (Rule 4) exists to repair.
# An EMPTY reply is not a state: it means the question could not be answered
# (no session bus, wrong scope flag), so it fails CLOSED. HEAD read the exit code,
# which failed closed on the same condition; parsing the output instead must not
# silently turn an unreadable state into permission to start the unit.
# Args: $1 — unit; $2 — declared unit path (unused: systemctl addresses units by
#       name, exactly as supervisor_start and supervisor_repair treat it — it is
#       accepted so every backend shares one arity); $3 — scope.
supervisor_enabled() {
  local unit="$1" scope="${3:-user}" state
  # check-suppress:suppression_doc: is-enabled fails for a unit without install info; that is not a user disable
  state="$(systemctl "$(_systemd_scope_args "$scope")" is-enabled "$unit" 2>/dev/null || true)"
  [ -n "$state" ] || return 1
  [ "$state" != "not-found" ] && [ "$state" != "disabled" ] && [ "$state" != "masked" ]
}

# supervisor_live — is the unit currently active?
# Args: $1 — the output of `systemctl status`.
supervisor_live() {
  local status_out="$1"
  case "$status_out" in
  *"Active: active"*) return 0 ;;
  esac
  return 1
}

# supervisor_generation — the unit's run token: a value that changes whenever the
# unit starts a new run.  systemd reports it as a monotonic restart count, so the
# watchdog sees a change exactly when the unit was restarted.
# WHY: not named for a count — on Windows the same contract is fed process
#   identity or a run timestamp, where no count exists.  The watchdog compares
#   only for inequality, so one name covers both.
# Args: $1 — unit; $2 — scope.
supervisor_generation() {
  local unit="$1" scope="${2:-user}" count
  # check-suppress:suppression_doc: a unit with no manager state has no counter; zero restarts is the correct reading
  count="$(systemctl "$(_systemd_scope_args "$scope")" show "$unit" -p NRestarts --value 2>/dev/null || true)"
  printf '%s' "${count:-0}"
}

# supervisor_last_exit — last exit status for the unit.
# Args: $1 — unit; $2 — scope.
supervisor_last_exit() {
  local unit="$1" scope="${2:-user}" code
  # check-suppress:suppression_doc: a unit with no manager state has no recorded exit; zero is the correct reading
  code="$(systemctl "$(_systemd_scope_args "$scope")" show "$unit" -p ExecMainStatus --value 2>/dev/null || true)"
  printf '%s' "${code:-0}"
}

# supervisor_start — start the unit.
# Args: $1 — unit; $2 — declared unit path (unused: systemctl addresses units by
#       name); $3 — scope.
supervisor_start() {
  local unit="$1" scope="${3:-user}"
  # check-suppress:suppression_doc: start fails when the unit is already active, which is the desired end state
  systemctl "$(_systemd_scope_args "$scope")" start "$unit" 2>/dev/null || true
}

# supervisor_stop — stop the unit.
# Args: $1 — unit; $2 — scope.
supervisor_stop() {
  local unit="$1" scope="${2:-user}"
  # check-suppress:suppression_doc: stop fails when the unit is already inactive, which is the desired end state
  systemctl "$(_systemd_scope_args "$scope")" stop "$unit" 2>/dev/null || true
}

# supervisor_repair — restart the unit.
# Args: $1 — unit; $2 — declared unit path (unused); $3 — scope.
supervisor_repair() {
  local unit="$1" scope="${3:-user}"
  # check-suppress:suppression_doc: restart fails when the unit is not loadable; the next tick retries
  systemctl "$(_systemd_scope_args "$scope")" restart "$unit" 2>/dev/null || true
}

# supervisor_kind — the supervisor kind identifier.
supervisor_kind() {
  printf 'systemd'
}
