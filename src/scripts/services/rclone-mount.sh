#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# Arguments: remote_name remote mount_point [additional rclone args...]
# rclone is resolved from PATH (provided via writeShellApplication runtimeInputs).
remote_name="${1:?remote name required}"
remote="${2:?remote required}"
mount_point="${3:?mount point required}"
shift 3

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
  "$@"
