#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# Configuration via environment variables (set by writeNucleusShellApplication extraEnv):
#   NUCLEUS_RCLONE_REMOTE_NAME  — rclone remote name (used for existence check)
#   NUCLEUS_RCLONE_REMOTE       — full remote path (e.g. "gdrive:backups")
#   NUCLEUS_RCLONE_MOUNT_POINT  — local mount point directory
#   NUCLEUS_RCLONE_ARGS         — additional rclone flags (newline-separated)
remote_name="${NUCLEUS_RCLONE_REMOTE_NAME:?NUCLEUS_RCLONE_REMOTE_NAME required}"
remote="${NUCLEUS_RCLONE_REMOTE:?NUCLEUS_RCLONE_REMOTE required}"
mount_point="${NUCLEUS_RCLONE_MOUNT_POINT:?NUCLEUS_RCLONE_MOUNT_POINT required}"

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
rclone mount \
  "$remote" \
  "$mount_point" \
  "${extra_args[@]}" \
  "$@" &
_mount_pid=$!

# WHY: forward termination to rclone, and then wait for rclone to finish exiting.
#   A stop request that leaves rclone unmounting in the background wedges the
#   macFUSE/FSKit volume for this path, and every later mount there is destroyed
#   seconds after it attaches.
# check-suppress:suppression_doc: rclone may already have exited; a failed signal to a dead process changes nothing about the report below.
trap '_mount_stopping=true; kill -TERM "$_mount_pid" 2>/dev/null || true' TERM INT

# WHY: a stop request interrupts 'wait' with a status above 128 (128+signo)
#   while rclone is still unmounting, and only a reaped child proves rclone has
#   really finished: a mount left unmounting in the background wedges the
#   macFUSE/FSKit volume for this path, and every later mount there is destroyed
#   seconds after it attaches.  The LaunchAgent's ExitTimeOut (60 s) bounds a
#   mount that never finishes.
_mount_status=0
while :; do
  if wait "$_mount_pid"; then
    _mount_status=0
  else
    _mount_status=$?
  fi
  # 127: an earlier 'wait' already reaped rclone, so there is nothing left to
  # wait for.  At or below 128: rclone's own exit status.  Anything above is the
  # stop signal that interrupted the wait, so rclone is still exiting.
  if [ "$_mount_status" -eq 127 ] || [ "$_mount_status" -le 128 ]; then
    break
  fi
done
trap - TERM INT

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
