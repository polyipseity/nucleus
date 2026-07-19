# Create system log directories for all nucleus systemd services before they
# start, so journald/stderr redirect targets exist on disk.
_sys_log_dir='__NUCLEUS_SYSTEM_LOG_DIR__'
_log_subdirs='__NUCLEUS_LOG_SUBDIRS__'
if [ -n "$_sys_log_dir" ]; then
  for subdir in $_log_subdirs; do
    mkdir -p "$_sys_log_dir/$subdir"
  done
fi
