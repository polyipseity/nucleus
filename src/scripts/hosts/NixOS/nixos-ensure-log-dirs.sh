# Create system log directories for all nucleus systemd services before they
# start, so journald/stderr redirect targets exist on disk.
# Expects env vars: NUCLEUS_SYSTEM_LOG_DIR, NUCLEUS_LOG_SUBDIRS
if [ -n "${NUCLEUS_SYSTEM_LOG_DIR:-}" ]; then
  for subdir in $NUCLEUS_LOG_SUBDIRS; do
    mkdir -p "$NUCLEUS_SYSTEM_LOG_DIR/$subdir"
  done
fi
