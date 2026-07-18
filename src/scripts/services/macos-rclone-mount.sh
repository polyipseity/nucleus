set -eu

# Verify the rclone remote is configured; exit 0 (no restart) if not.
if ! rclone_remotes="$(__RCLONE_BIN__ listremotes)"; then
  echo "cloud-drives: failed to list rclone remotes for '__RCLONE_REMOTE_NAME__' mount; check the config passphrase and remote configuration." >&2
  exit 1
fi

case "$rclone_remotes" in
  *__RCLONE_REMOTE_NAME__:*)
    ;;
  *)
    echo "cloud-drives: rclone remote '__RCLONE_REMOTE_NAME__' not configured; mount skipped." >&2
    echo "cloud-drives: run 'rclone config' to set up the remote, then re-run 'home-manager switch'." >&2
    exit 0
    ;;
esac

exec __RCLONE_BIN__ mount \
  __RCLONE_REMOTE__ \
  __RCLONE_MOUNT_POINT__ \
  __RCLONE_ARGS__
