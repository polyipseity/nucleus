#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/crash-loop.sh
. "$SCRIPT_DIR/../lib/crash-loop.sh"
# shellcheck source=../lib/macos-fskit.sh
. "$SCRIPT_DIR/../lib/macos-fskit.sh"
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

# Configuration via environment variables (set by writeNucleusShellApplication extraEnv):
#   NUCLEUS_RCLONE_REMOTE_NAME          — rclone remote name (used for existence check)
#   NUCLEUS_RCLONE_REMOTE               — full remote path (e.g. "gdrive:backups")
#   NUCLEUS_RCLONE_MOUNT_POINT          — local mount point directory
#   NUCLEUS_RCLONE_ARGS                 — additional rclone flags (newline-separated)
#   NUCLEUS_CLOUD_MOUNT_INSTANCE        — LaunchAgent label, the key a blocked marker is written under
#   NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT — seconds the volume may take to attach (default 120)
#   NUCLEUS_CLOUD_MOUNT_DECAY_INTERVAL  — seconds between checks for a volume that vanished (default 60)
remote_name="${NUCLEUS_RCLONE_REMOTE_NAME:?NUCLEUS_RCLONE_REMOTE_NAME required}"
remote="${NUCLEUS_RCLONE_REMOTE:?NUCLEUS_RCLONE_REMOTE required}"
mount_point="${NUCLEUS_RCLONE_MOUNT_POINT:?NUCLEUS_RCLONE_MOUNT_POINT required}"
instance="${NUCLEUS_CLOUD_MOUNT_INSTANCE:?NUCLEUS_CLOUD_MOUNT_INSTANCE required}"

extra_args=()
while IFS= read -r _arg; do
  [[ -n "$_arg" ]] && extra_args+=("$_arg")
done <<<"${NUCLEUS_RCLONE_ARGS-}"

# Verify the rclone remote is configured; exit 0 (no restart) if not.
if ! rclone_remotes="$(rclone listremotes)"; then
  die -l cloud-drives "failed to list rclone remotes for '$remote_name' mount; check the config passphrase and remote configuration."
fi

case "$rclone_remotes" in
*"$remote_name":*)
  ;;
*)
  warn -l cloud-drives "rclone remote '$remote_name' not configured; mount skipped."
  warn -l cloud-drives "run 'rclone config' to set up the remote, then re-run 'home-manager switch'."
  exit 0
  ;;
esac

# _cd_attach_timeout — NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT as a positive integer.
# WHY: the value bounds an arithmetic loop, so a malformed override falls back to
#   the default instead of aborting or spinning without a bound.
_cd_attach_timeout() {
  case "${NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT:-}" in
  '' | *[!0-9]* | 0) printf '120\n' ;;
  *) printf '%s\n' "$NUCLEUS_CLOUD_MOUNT_ATTEMPT_TIMEOUT" ;;
  esac
}

# The attempt bound, resolved once: the watcher, the stall report and the copy of
# rclone's output into the log all read it, and an override must not be re-parsed
# per use.
_cd_attach_seconds="$(_cd_attach_timeout)"

# _cd_decay_interval — seconds between checks for a volume that vanished.
# WHY: an attached volume that is destroyed later is the same provider failure
#   found later, and the interval is overridable so the watcher's contract can be
#   exercised in seconds instead of minutes.
_cd_decay_interval() {
  case "${NUCLEUS_CLOUD_MOUNT_DECAY_INTERVAL:-}" in
  '' | *[!0-9]* | 0) printf '60\n' ;;
  *) printf '%s\n' "$NUCLEUS_CLOUD_MOUNT_DECAY_INTERVAL" ;;
  esac
}

# _cd_run_bounded <seconds> <command...> — run a command under a wall-clock bound.
# Exit: the command's own status, or 124 when the bound elapsed.
# WHY: a hung macFUSE/FSKit volume blocks mount(8) and diskutil inside the
#   kernel, and this script has no 'timeout' binary on PATH, so every probe that
#   can touch a mount carries its own bound.
_cd_run_bounded() {
  _rb_bound="$1"
  shift
  _rb_ticks=0
  _rb_max=$((_rb_bound * 5))
  "$@" &
  _rb_pid=$!
  while kill -0 "$_rb_pid" 2>/dev/null; do
    if [ "$_rb_ticks" -ge "$_rb_max" ]; then
      # check-suppress:suppression_doc: the command already outlived its bound; the signals and the reap are best effort and the bound is the answer.
      kill -TERM "$_rb_pid" 2>/dev/null || true
      sleep 0.2
      # check-suppress:suppression_doc: same as above — the bound is the answer, not the cleanup.
      kill -KILL "$_rb_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: same as above.
      wait "$_rb_pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    _rb_ticks=$((_rb_ticks + 1))
  done
  _rb_status=0
  wait "$_rb_pid" || _rb_status=$?
  return "$_rb_status"
}

# _cd_mount_table_has <path> — whether the mount table lists PATH.
# Returns 0 when mounted, 1 when not.  A probe that outlives its bound counts as
# mounted, so nothing is ever mounted on top of a volume that cannot be listed.
_cd_mount_table_has() {
  _mth_status=0
  _mth_table=""
  # check-suppress:suppression_doc: a probe that fails or outlives its bound is classified below; its own status is not the answer.
  _mth_table="$(_cd_run_bounded 10 mount)" || _mth_status=$?
  if [ "$_mth_status" -eq 124 ]; then
    return 0
  fi
  case "$_mth_table" in
  *" on $1 ("*) return 0 ;;
  esac
  return 1
}

# Capture of rclone's stderr, classified when the mount fails.
# WHY: the reason a mount is refused (FSKit's "file system extension not
#   found"/"not enabled", or mount(8) returning 69) is written to stderr by
#   macFUSE just before rclone exits, and the wrapper has to read it to tell a
#   provider failure from a remote failure.  A copier mirrors the capture back
#   into the wrapper's own stderr, which is the LaunchAgent's stderr.log, so that
#   log keeps every line rclone wrote — a pipe would do the same until it breaks,
#   while rclone writing to a file cannot fail at all.
_cd_capture="$(mktemp "${TMPDIR:-/tmp}/nucleus-cloud-mount.XXXXXX")"
_cd_stalled="$_cd_capture.stalled"
_cd_decayed="$_cd_capture.decayed"
_cd_watcher=""
_cd_copier=""

# _cd_start_copier — Mirror rclone's captured stderr into this wrapper's stderr.
_cd_start_copier() {
  tail -n +1 -F "$_cd_capture" >&2 &
  _cd_copier=$!
}

# _cd_stop_watcher — End the attempt watcher and reap it.
_cd_stop_watcher() {
  [ -n "$_cd_watcher" ] || return 0
  # check-suppress:suppression_doc: the watcher may have finished on its own; a failed signal to a dead process changes nothing.
  kill -TERM "$_cd_watcher" 2>/dev/null || true
  # check-suppress:suppression_doc: same as above — the reap only avoids a zombie.
  wait "$_cd_watcher" 2>/dev/null || true
  _cd_watcher=""
}

# shellcheck disable=SC2329 # reason: invoked via the EXIT trap, not directly
_cd_cleanup_capture() {
  _cd_stop_watcher
  if [ -n "$_cd_copier" ]; then
    # check-suppress:suppression_doc: the copier reads a file that is removed below; a failed signal to a finished copier changes nothing at exit.
    kill -TERM "$_cd_copier" 2>/dev/null || true
    # check-suppress:suppression_doc: same as above.
    wait "$_cd_copier" 2>/dev/null || true
    _cd_copier=""
  fi
  rm -f "$_cd_capture" "$_cd_stalled" "$_cd_decayed"
}
trap '_cd_cleanup_capture' EXIT

# _cd_watch_mount <rclonePid> <attemptSeconds> [decaySeconds] — bound the attach
# and notice a volume that vanishes, from a background process.
# WHY a background watcher instead of a poll in the foreground: bash reaps a
#   child only through 'wait', and 'kill -0' cannot tell an exited child from a
#   running one before that, so the bound has to run beside the wait for the wait
#   to still report rclone's own status.  A volume that never attaches within the
#   bound is stuck — macFUSE parks the mount behind a modal "unexpected error"
#   dialog that writes nothing to the console (observed parked for 3573s) — and a
#   volume that vanishes after it attached is the same failure found later, so both
#   end the attempt instead of leaving it mounted-but-dead.
_cd_watch_mount() {
  local pid="$1" attempt="$2" decay="${3:-60}" attached=false
  local second=0

  # WHY one-second ticks around every probe: a watcher that is stopped must not
  #   leave a minute-long sleeper behind, and the wrapper stops it as soon as the
  #   mount ends.
  while [ "$second" -lt "$attempt" ]; do
    sleep 1
    second=$((second + 1))
    if _cd_mount_table_has "$mount_point"; then
      attached=true
      # WHY: the provider served a volume, so it is healthy again: whatever
      #   blocked an earlier attempt is over.
      svc_blocked_clear "$instance" "$(crash_loop_state_dir)"
      break
    fi
  done

  if [ "$attached" = false ]; then
    : >"$_cd_stalled"
    # check-suppress:suppression_doc: rclone may have exited on its own; the signal is best effort because the wrapper reports that exit itself.
    kill -TERM "$pid" 2>/dev/null || true
    return 0
  fi
  while :; do
    second=0
    while [ "$second" -lt "$decay" ]; do
      sleep 1
      second=$((second + 1))
    done
    if ! _cd_mount_table_has "$mount_point"; then
      : >"$_cd_decayed"
      # check-suppress:suppression_doc: same as above — the wrapper reads the exit status, the signal only ends the attempt.
      kill -TERM "$pid" 2>/dev/null || true
      return 0
    fi
  done
}

# _cd_fskit_provider — whether this host mounts through macFUSE's FSKit provider.
# WHY: FSKit, its park-without-output failure mode and the 'sudo killall fskitd'
#   remedy exist only on macOS.  The same wrapper serves NixOS over fuse3, where a
#   bound that elapsed or a libfuse refusal is an ordinary mount failure the
#   supervisor has to retry: a block written there could never be cleared, because
#   the remedy cannot run on that host.  uname is the OS boundary rather than the
#   host registry — resolving a host key would put a jq and repo-checkout
#   dependency on a service hot path for a fact the kernel already answers.
_cd_fskit_provider() {
  case "$(uname -s)" in
  Darwin) return 0 ;;
  esac
  return 1
}

# _cd_provider_failure — whether macFUSE's FSKit provider, not the remote,
# refused the mount.  Always false off macOS (see _cd_fskit_provider).
# WHY: only 'disabled' counts from the probe.  FSKit's module list can still name
#   the module while the client is told "not enabled" (and the reverse), so the
#   probe alone cannot decide — but a probe that cannot read the list answers
#   'unknown' and must never block a mount that could succeed.
# ref: https://github.com/macfuse/macfuse/issues/1132
_cd_provider_failure() {
  _cd_fskit_provider || return 1
  if grep -qE 'File system extension not (found|enabled)|fuse: mount failed with error|mount\(8\) returned 69' "$_cd_capture"; then
    return 0
  fi
  [ "$(fskit_macfuse_module_state)" = "disabled" ]
}

# _cd_block_on_provider_failure <reason> — stop this mount and report the remedy.
# Never returns: exit 0 keeps KeepAlive{SuccessfulExit:false} from reloading a
# mount the provider refuses again, and the blocked marker is what 'nucleus-svc
# status' and the watchdog read instead of retrying it.
_cd_block_on_provider_failure() {
  local reason="$1" remedy
  remedy="$(fskit_remedy)"
  svc_blocked_set "$instance" "$(crash_loop_state_dir)" fskit-provider "$remedy"
  # check-suppress:suppression_doc: error's status is consumed because this path exits 0 on purpose, to stop the retry loop.
  error -l cloud-drives "the macFUSE/FSKit provider refused the mount of '$mount_point' ($reason); the mount is stopped instead of retried." || true
  # check-suppress:suppression_doc: same as above.
  error -l cloud-drives "$remedy" || true
  exit 0
}

# WHY: a volume that is still attached here is the leftover of a mount that did
#   not finish unmounting (or a foreign mount), and mounting on top of it gets
#   the new volume destroyed seconds later.  It is released first, and refused
#   when it cannot be, because only an operator can clear a wedged volume.
if _cd_mount_table_has "$mount_point"; then
  warn -l cloud-drives "a volume is still attached at '$mount_point'; releasing it before mounting."
  _cd_unmount_status=0
  if command -v diskutil >/dev/null 2>&1; then
    # check-suppress:suppression_doc: the outcome is read back from the mount table below, so this command's own status is only reported with the refusal.
    _cd_run_bounded 30 diskutil unmount force "$mount_point" >/dev/null 2>&1 || _cd_unmount_status=$?
  fi
  if _cd_mount_table_has "$mount_point"; then
    error -l cloud-drives "volume at '$mount_point' is still attached after 'diskutil unmount force' (status $_cd_unmount_status); refusing to mount over it. Release it with 'sudo umount -f \"$mount_point\"' and re-apply, or reboot."
    exit 1
  fi
fi

# Run rclone in the foreground instead of exec'ing it, so its exit is always
# reported and a stop request is never left half-done.
#
# WHY: rclone reports a mount that decays — the volume is destroyed seconds after
#   it attaches, so the path never serves anything — as a NOTICE-level unmount
#   followed by exit 0, and the LaunchAgent's KeepAlive{SuccessfulExit:false}
#   never retries a status of 0.  A clean exit is indistinguishable from a
#   healthy idle mount, so the one place that sees both the status and the
#   lifetime reports it.
_mount_started="$SECONDS"
_mount_stopping=false
_mount_interrupted=false
_cd_start_copier
rclone mount \
  "$remote" \
  "$mount_point" \
  "${extra_args[@]}" \
  "$@" 2>"$_cd_capture" &
_mount_pid=$!

_cd_watch_mount "$_mount_pid" "$_cd_attach_seconds" "$(_cd_decay_interval)" &
_cd_watcher=$!

# WHY: forward termination to rclone, and then wait for rclone to finish exiting.
#   A stop request that leaves rclone unmounting in the background wedges the
#   macFUSE/FSKit volume for this path, and every later mount there is destroyed
#   seconds after it attaches.
# check-suppress:suppression_doc: rclone may already have exited; a failed signal to a dead process changes nothing about the report below.
trap '_mount_stopping=true; _mount_interrupted=true; kill -TERM "$_mount_pid" 2>/dev/null || true' TERM INT

# Wait for rclone, and repeat the wait when a stop signal interrupted it: the
# interrupted wait reports the signal (128+signo), not rclone's status.  The
# repeat is driven by the flag, never by the status — bash replays the cached
# status of an already-reaped child, so a status of 137 or 143 would otherwise
# keep this loop spinning until launchd's ExitTimeOut killed it.
_mount_status=0
while :; do
  _mount_interrupted=false
  if wait "$_mount_pid"; then
    _mount_status=0
  else
    _mount_status=$?
  fi
  if [ "$_mount_interrupted" = false ]; then
    break
  fi
done
trap - TERM INT

# End the watcher: the attempt is over, and a watcher left behind would signal
# this path's next mount.
_cd_stop_watcher

_mount_seconds=$((SECONDS - _mount_started))

if [ "$_mount_stopping" = true ]; then
  # WHY: a requested stop is the expected end of this mount, so it is not a
  #   failure, and exit 0 keeps KeepAlive{SuccessfulExit:false} from resurrecting
  #   a job the operator just stopped.  A stop that did not release the volume is
  #   still reported.
  if [ "$_mount_status" -ne 0 ]; then
    warn -l cloud-drives "rclone mount for '$mount_point' exited with status $_mount_status after ${_mount_seconds}s (stop requested)."
  fi
  exit 0
fi

# WHY: macFUSE prints the reason a mount was refused just before rclone exits, and
#   the copier mirrors the capture in its own process, so the capture is given a
#   moment to be complete and mirrored before anything is decided on it.
sleep 0.3

if _cd_provider_failure; then
  _cd_block_on_provider_failure "see the macFUSE message above"
fi

if [ -e "$_cd_stalled" ]; then
  # WHY: a mount that is still running with no volume after the bound is how a
  #   wedged macFUSE provider looks from the console — the attempt is parked
  #   behind a modal dialog that writes nothing — so on macOS it is reported and
  #   stopped instead of retried into the same park.  Elsewhere only the bound
  #   applies: the attempt is stopped and failed, which is what reloads the mount.
  if _cd_fskit_provider; then
    _cd_block_on_provider_failure "no volume attached within ${_cd_attach_seconds}s while rclone was still running (a macFUSE dialog parks a mount without console output)"
  fi
  error -l cloud-drives "no volume attached at '$mount_point' within ${_cd_attach_seconds}s while rclone was still running; the attempt was stopped and the mount is reloaded."
  exit 1
fi

if [ -e "$_cd_decayed" ]; then
  error -l cloud-drives "the volume at '$mount_point' disappeared ${_mount_seconds}s after it attached; the mount is reloaded so the path serves data again."
  exit 1
fi

if [ "$_mount_status" -eq 0 ]; then
  warn -l cloud-drives "rclone mount for '$mount_point' exited with status 0 after ${_mount_seconds}s without a live mount; check the remote and the mount point."
  # WHY: rclone exits 0 both when its volume is destroyed seconds after the mount
  #   appeared and when the mount never attached, so a clean exit here is a
  #   failure: exit non-zero to let KeepAlive{SuccessfulExit:false} reload the
  #   mount (launchd throttles the retry) rather than leave the drive missing
  #   until the next reboot.  The next start releases a leftover volume first.
  exit 1
fi
warn -l cloud-drives "rclone mount for '$mount_point' exited with status $_mount_status after ${_mount_seconds}s."
exit "$_mount_status"
