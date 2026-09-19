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
else
  warn -l cloud-drives "rclone mount for '$mount_point' exited with status $_mount_status after ${_mount_seconds}s."
fi
exit "$_mount_status"
