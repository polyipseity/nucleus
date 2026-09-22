# shellcheck shell=bash
# FSKit provider state for the macFUSE file-system extension (macOS).
#
# macOS serves macFUSE volumes through an FSKit file-system module
# (io.macfuse.app.fsmodule.macfuse and its -local variant) owned by the FSKit
# subsystem (fskitd).  macFUSE 5.x can leave that subsystem wedged after an
# unmount: the client then reports "File system extension not found" (macFUSE
# status 3), "File system extension not enabled" (4) and "mount(8) returned 69"
# (EX_UNAVAILABLE), while FSKit's on-disk module list still names the module.
# The list therefore gates a mount attempt but never proves one will succeed,
# and the remedy is a daemon restart, not a re-registration.
# ref: https://github.com/macfuse/macfuse/issues/1132
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "$SCRIPT_DIR/../lib/macos-fskit.sh"
#   state="$(fskit_macfuse_module_state)"   # enabled|disabled|unknown
#   fskit_restart_daemon 30                 # kill fskitd, wait for the new daemon
#
# Callers gate on the host: every probe answers "unknown"/"stopped" when the
# macOS-only tools are absent, so a caller that must not act on macOS keeps its
# own host check instead of relying on a probe to fail loudly.
#
# Pure function definitions only — no top-level side effects on import.

[ -n "${_NUCLEUS_MACOS_FSKIT_SOURCED-}" ] && return
_NUCLEUS_MACOS_FSKIT_SOURCED=1

# Bundle identifiers the macFUSE FSKit extension registers under.  A re-register
# can drop the main identifier and keep the -local one, so both count.
FSKIT_MACFUSE_BUNDLE_IDS="io.macfuse.app.fsmodule.macfuse io.macfuse.app.fsmodule.macfuse-local"

# FSKit's system daemon.  A restart is the remedy the macFUSE maintainers give
# for a wedged subsystem; launchctl cannot perform it (SIP refuses kickstart).
FSKIT_DAEMON_LABEL="com.apple.filesystems.fskitd"

# fskit_settings_plist — Path of the plist listing FSKit's enabled modules.
# WHY: FSKit's own list, not PluginKit — pkd rejects a file-system module that
#   is not inside a SIP-protected app, so a pluginkit probe reports the macFUSE
#   module as absent even while its volumes mount successfully.
fskit_settings_plist() {
  printf '%s/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist\n' "${HOME:-}"
}

# fskit_remedy — Operator remedy for a wedged FSKit provider, for status output
# and blocked markers.
fskit_remedy() {
  printf 'run '\''sudo killall fskitd'\'' (nucleus-cloud repair), then re-enable macFUSE in System Settings > General > Login Items & Extensions > By category > File System Extensions when it is missing from FSKit'\''s module list\n'
}

# fskit_module_state <bundleID> — "enabled", "disabled", or "unknown".
# WHY: "unknown" for an unreadable list, never "disabled": the probe decides
#   whether an attempt is skipped, so a probe failure must not read as a
#   missing module.
fskit_module_state() {
  local bundle_id="$1" plist listing
  [ -n "$bundle_id" ] || return 1
  plist="$(fskit_settings_plist)"
  if [ ! -r "$plist" ] || ! command -v plutil >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  if ! listing="$(plutil -p "$plist" 2>/dev/null)"; then
    printf 'unknown\n'
    return 0
  fi
  if printf '%s\n' "$listing" | grep -qF "\"$bundle_id\""; then
    printf 'enabled\n'
  else
    printf 'disabled\n'
  fi
}

# fskit_macfuse_module_state — "enabled" when any macFUSE module is listed,
# "disabled" when the list is readable and names none, "unknown" otherwise.
fskit_macfuse_module_state() {
  local bundle_id state
  state="unknown"
  for bundle_id in $FSKIT_MACFUSE_BUNDLE_IDS; do
    state="$(fskit_module_state "$bundle_id")"
    if [ "$state" = "enabled" ]; then
      printf 'enabled\n'
      return 0
    fi
    if [ "$state" = "unknown" ]; then
      printf 'unknown\n'
      return 0
    fi
  done
  printf 'disabled\n'
}

# fskit_daemon_pid — PID of the FSKit daemon, empty when it is not running.
fskit_daemon_pid() {
  if ! command -v launchctl >/dev/null 2>&1; then return 0; fi
  # check-suppress:suppression_doc: the daemon may be absent or SIGPIPE the probe; an empty PID is the answer this reports.
  launchctl print "system/$FSKIT_DAEMON_LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}' || true
}

# fskit_daemon_state — "running" or "stopped" for the FSKit daemon.
fskit_daemon_state() {
  if [ -n "$(fskit_daemon_pid)" ]; then
    printf 'running\n'
  else
    printf 'stopped\n'
  fi
}

# fskit_restart_daemon [waitSeconds] — Restart the FSKit subsystem.
# WHY: killall, not launchctl kickstart — SIP refuses to kickstart this system
#   daemon (exit 150, "Operation not permitted while System Integrity Protection
#   is engaged"), while a signal restarts it through launchd.
# Returns non-zero when the daemon does not come back with a new PID within the
# bound; the caller reports the remedy instead of retrying the mount blindly.
fskit_restart_daemon() {
  local wait_seconds="${1:-30}"
  local pid_before pid_after ticks max_ticks kill_status=0

  if ! command -v killall >/dev/null 2>&1; then
    error "fskit: killall not found; cannot restart $FSKIT_DAEMON_LABEL"
    return 1
  fi

  pid_before="$(fskit_daemon_pid)"
  if [ "$(id -u)" -eq 0 ]; then
    killall fskitd || kill_status=$?
  else
    if ! command -v sudo >/dev/null 2>&1; then
      error "fskit: sudo not found; run 'sudo killall fskitd' as an operator"
      return 1
    fi
    sudo killall fskitd || kill_status=$?
  fi
  if [ "$kill_status" -ne 0 ]; then
    error "fskit: 'killall fskitd' failed ($kill_status); run it as an operator and retry"
    return 1
  fi

  ticks=0
  max_ticks=$((wait_seconds * 2))
  while [ "$ticks" -lt "$max_ticks" ]; do
    sleep 0.5
    ticks=$((ticks + 1))
    pid_after="$(fskit_daemon_pid)"
    if [ -n "$pid_after" ] && [ "$pid_after" != "$pid_before" ]; then
      return 0
    fi
  done

  error "fskit: $FSKIT_DAEMON_LABEL did not restart within ${wait_seconds}s; retry, or reboot"
  return 1
}

# fskit_repair_provider [waitSeconds] — Repair the provider: restart the FSKit
# subsystem, then report whether the macFUSE module is usable again.
# Output: "ok" when the daemon respawned and a macFUSE module is listed,
# "module-disabled" when it respawned but no module is listed (only the operator
# can re-enable it), "unknown" when the module list cannot be read.
# Returns non-zero for everything but "ok", and prints the remedy with the error.
# WHY the module check after the restart: a restart fixes a wedged subsystem,
#   never a module that FSKit no longer serves, and the two are indistinguishable
#   from the client side (both report "not enabled").
fskit_repair_provider() {
  local state

  if ! fskit_restart_daemon "${1:-60}"; then
    return 1
  fi
  state="$(fskit_macfuse_module_state)"
  case "$state" in
  enabled)
    printf 'ok\n'
    ;;
  disabled)
    error "fskit: macFUSE is missing from FSKit's module list; enable it in System Settings > General > Login Items & Extensions > By category > File System Extensions, then retry"
    printf 'module-disabled\n'
    return 1
    ;;
  *)
    error "fskit: could not read FSKit's module list; check that the macFUSE file-system extension is enabled"
    printf 'unknown\n'
    return 1
    ;;
  esac
}
