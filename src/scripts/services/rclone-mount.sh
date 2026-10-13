#!/usr/bin/env bash
# Minimal cloud-mount supervisor step: mode `mount` cleans stale state and
# execs rclone in the foreground so the platform manager (launchd KeepAlive,
# systemd Restart=always) owns revival; mode `clean` is the systemd
# ExecStartPre hook. There is no health record, no attach loop, and no
# classification by design: rclone's own exit plus the retained log is the
# entire failure surface (rclone/rclone#9899: supervisors own backoff).
#
# CLI:
#   rclone-mount.sh mount <instance> <log-file> <mount-point> <remote-spec> [rclone-flags...]
#   rclone-mount.sh clean <mount-point>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# WHY: mount(8) and umount(8) are OS tools outside the managed profile, so
#   they are resolved explicitly and prepended into PATH instead of trusted
#   from an ambient PATH the wrapper does not control.
_nucleus_mount_bin="$(command -v mount)" || die "mount(8) must be resolvable on PATH"
_nucleus_umount_bin="$(command -v umount)" || die "umount(8) must be resolvable on PATH"
PATH="$(dirname "$_nucleus_mount_bin"):$(dirname "$_nucleus_umount_bin"):$PATH"

usage() {
  usage_std "$(basename "$0")" "mount <instance> <log-file> <mount-point> <remote-spec> [rclone-flags...]"
  usage_std "$(basename "$0")" "clean <mount-point>"
}

# Force-unmount a stale entry, then guarantee a fresh empty directory. Every
# step is best-effort because the mount may be healthy or already gone; the
# mount-table check after the loop is what decides, and rclone reports a real
# failure itself.
clean_mount_point() {
  local mount_point="$1" _clean_i
  if mount | grep -qF " on $mount_point ("; then
    # check-suppress:suppression_doc: best-effort stale unmount, re-checked by the poll below
    umount -f "$mount_point" 2>/dev/null || true
    for _clean_i in 1 2 3 4 5; do
      mount | grep -qF " on $mount_point (" || break
      sleep 1
    done
  fi
  # WHY rmdir before mkdir: a mount torn down uncleanly can leave an inode the
  #   kernel refuses to traverse; recreating the directory clears it. rmdir
  #   fails harmlessly on a non-empty directory, which then stays put.
  # check-suppress:suppression_doc: best-effort recreate, rclone fails loudly if the path stays bad
  rmdir "$mount_point" 2>/dev/null || true
  mkdir -p "$mount_point"
}

case "${1:-}" in
clean)
  [ "$#" -eq 2 ] || {
    usage >&2
    exit 2
  }
  clean_mount_point "$2"
  exit 0
  ;;
mount)
  shift
  [ "$#" -ge 4 ] || {
    usage >&2
    exit 2
  }
  # WHY unbound: <instance> is a positional contract for the call site and
  #   the log file path already carries the identity, so the value is
  #   consumed positionally and never read here. Binding it would be an
  #   unused variable.
  _rclone_log="$2"
  _rclone_mount_point="$3"
  _rclone_remote="$4"
  shift 4
  clean_mount_point "$_rclone_mount_point"
  mkdir -p "$(dirname "$_rclone_log")"
  exec rclone mount "$_rclone_remote" "$_rclone_mount_point" "$@" >>"$_rclone_log" 2>&1
  ;;
*)
  usage >&2
  exit 2
  ;;
esac
