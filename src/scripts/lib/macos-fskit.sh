# shellcheck shell=bash
# FSKit provider state for the macFUSE file-system extension (macOS).
#
# macFUSE 5.x can wedge fskitd after an unmount: the client then reports "File
# system extension not found" (3), "not enabled" (4) and "mount(8) returned 69"
# (EX_UNAVAILABLE) while FSKit's on-disk module list still names the module. The
# list gates an attempt but never proves one succeeds, and the remedy is a daemon
# restart, not a re-registration.
# ref: https://github.com/macfuse/macfuse/issues/1132
#
# Every probe answers "unknown"/"stopped" when the macOS-only tools are absent,
# so a caller that must not act on macOS keeps its own host check.

[ -n "${_NUCLEUS_MACOS_FSKIT_SOURCED-}" ] && return
_NUCLEUS_MACOS_FSKIT_SOURCED=1

# A re-register can drop the main identifier and keep the -local one, so both count.
FSKIT_MACFUSE_BUNDLE_IDS="io.macfuse.app.fsmodule.macfuse io.macfuse.app.fsmodule.macfuse-local"

# WHY: a signal restarts it through launchd, launchctl kickstart is refused by SIP.
FSKIT_DAEMON_LABEL="com.apple.filesystems.fskitd"

# WHY: FSKit's own list, not PluginKit. pkd rejects a file-system module outside
# a SIP-protected app, so a pluginkit probe reports macFUSE absent while its
# volumes mount fine.
fskit_settings_plist() {
  printf '%s/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist\n' "${HOME:-}"
}

fskit_remedy() {
  printf 'run '\''sudo killall fskitd'\'' (nucleus-cloud repair), then re-enable macFUSE in System Settings > General > Login Items & Extensions > By category > File System Extensions when it is missing from FSKit'\''s module list\n'
}

# WHY: "unknown" for an unreadable list, never "disabled". The probe decides
# whether an attempt is skipped, so a probe failure must not read as a missing
# module.
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

# WHY `unknown` counts as not enabled: a failed probe cannot prove the
# extension is on, so the caller re-registers and its own case on the module
# state decides the outcome.
fskit_extension_is_enabled() {
  [ "$(fskit_macfuse_module_state)" = "enabled" ]
}

# WHY `unknown` and empty stay apart: a probe that cannot run (launchctl missing
# or exiting non-zero) answers `unknown`, while a readable probe that reports no
# daemon answers empty. fskit_restart_daemon treats the first as a repair it
# cannot verify and the second as an idle daemon that needs no restart, so a
# probe error must not collapse into the idle answer.
fskit_daemon_pid() {
  local output status=0
  if ! command -v launchctl >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  # check-suppress:suppression_doc: the capture keeps a failing probe from killing a set -e caller and the
  #   status is classified below rather than propagated. The empty capture now feeds fskit_restart_daemon's
  #   idle-skip, so collapsing a probe error into empty would turn unreadable state into false success.
  output="$(launchctl print "system/$FSKIT_DAEMON_LABEL" 2>/dev/null)" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "$output" | awk '/pid =/{print $3; exit}'
}

# WHY unknown is its own state: a failed probe proves neither a running nor a
# stopped daemon, and a caller that acts on the answer must see the difference.
fskit_daemon_state() {
  local pid
  pid="$(fskit_daemon_pid)"
  if [ "$pid" = "unknown" ]; then
    printf 'unknown\n'
  elif [ -n "$pid" ]; then
    printf 'running\n'
  else
    printf 'stopped\n'
  fi
}

# WHY: killall, not launchctl kickstart, SIP refuses to kickstart this system
# daemon (exit 150). fskitd(8) is demand-start: launchd runs it for a volume
# request and it exits when idle, so an idle daemon needs no restart and an
# empty PID after the kill is the normal outcome. Non-zero when the state
# cannot be read, when killall is unavailable or fails, and when the daemon
# survives the kill and keeps its PID past the bound, so each path reports its
# own message and the caller can hand the operator the remedy instead of
# retrying the mount blindly.
fskit_restart_daemon() {
  local wait_seconds="${1:-30}"
  local pid_before pid_after ticks max_ticks kill_status=0

  pid_before="$(fskit_daemon_pid)"
  if [ "$pid_before" = "unknown" ]; then
    error "fskitd state could not be read (launchctl probe failed); repair cannot verify the daemon"
    return 1
  fi
  # WHY: nothing to restart: the next volume request starts the daemon, and
  # killall on an absent process only fails (it exits 1 when nothing matches).
  if [ -z "$pid_before" ]; then
    return 0
  fi

  if ! command -v killall >/dev/null 2>&1; then
    error "fskit: killall not found; cannot restart $FSKIT_DAEMON_LABEL"
    return 1
  fi

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
    # WHY: an empty PID means the daemon exited and launchd runs it again on the
    # next volume request, a different PID means it already respawned. Only the
    # killed PID still being there is the failure.
    if [ -z "$pid_after" ] || [ "$pid_after" != "$pid_before" ]; then
      return 0
    fi
  done

  error "fskit: $FSKIT_DAEMON_LABEL ignored SIGTERM and is still running after ${wait_seconds}s; run 'sudo killall -9 fskitd' as an operator, then reboot if the daemon survives"
  return 1
}

# WHY the module check after the restart: a restart fixes a wedged subsystem,
# never a module FSKit no longer serves, and the client side cannot tell them
# apart since both report "not enabled".
fskit_repair_provider() {
  local state

  if ! fskit_restart_daemon "${1:-15}"; then
    return 1
  fi
  state="$(fskit_macfuse_module_state)"
  case "$state" in
  enabled) ;;
  disabled)
    error "fskit: macFUSE is missing from FSKit's module list; enable it in System Settings > General > Login Items & Extensions > By category > File System Extensions, then retry"
    return 1
    ;;
  *)
    error "fskit: could not read FSKit's module list; check that the macFUSE file-system extension is enabled"
    return 1
    ;;
  esac
}
