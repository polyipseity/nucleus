#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# Configuration via environment variables (set by writeNucleusShellApplication extraEnv):
#   NUCLEUS_RCLONE_REMOTE_NAME  — rclone remote name (used for existence check)
#   NUCLEUS_RCLONE_REMOTE       — full remote path (e.g. "gdrive:backups")
#   NUCLEUS_RCLONE_MOUNT_POINT  — local mount point directory
#   NUCLEUS_RCLONE_ARGS         — additional rclone flags (space-separated)
remote_name="${NUCLEUS_RCLONE_REMOTE_NAME:?NUCLEUS_RCLONE_REMOTE_NAME required}"
remote="${NUCLEUS_RCLONE_REMOTE:?NUCLEUS_RCLONE_REMOTE required}"
mount_point="${NUCLEUS_RCLONE_MOUNT_POINT:?NUCLEUS_RCLONE_MOUNT_POINT required}"

# shellcheck disable=SC2206 # reason: word splitting intentional — space-separated args string → array
extra_args=(${NUCLEUS_RCLONE_ARGS-})

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

exec rclone mount \
  "$remote" \
  "$mount_point" \
  "${extra_args[@]}" \
  "$@"
