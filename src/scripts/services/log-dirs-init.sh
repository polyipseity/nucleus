# Create system log directories for all nucleus systemd/launchd services before
# they start, so journald/stderr redirect targets exist on disk.
_sys_log_dir='__NUCLEUS_SYSTEM_LOG_DIR__'
_log_subdirs='__NUCLEUS_LOG_SUBDIRS__'
if [ -n "$_sys_log_dir" ]; then
  for subdir in $_log_subdirs; do
    mkdir -p "$_sys_log_dir/$subdir"
  done
fi

# macOS-specific: create user-level log dirs in ~/Library/Logs/nucleus/ and
# chown system log subdirs to the console user so launchd can write.
_user_log_subdirs='__NUCLEUS_USER_LOG_SUBDIRS__'
_chown_log_subdirs='__NUCLEUS_CHOWN_LOG_SUBDIRS__'
if [ "$(uname -s)" = "Darwin" ] && [ -n "$_user_log_subdirs" ]; then
  _console_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"  # undoc-supp: /dev/console may not exist in headless/SSH sessions
  if [ -n "$_console_user" ] && [ "$_console_user" != "/Users/root" ]; then
    _username="${_console_user#/Users/}"
    for subdir in $_user_log_subdirs; do
      /bin/mkdir -p "$_console_user/Library/Logs/nucleus/$subdir"
    done
    /usr/sbin/chown -R "$_username:staff" "$_console_user/Library/Logs/nucleus"

    for subdir in $_chown_log_subdirs; do
      /usr/sbin/chown "$_username:staff" "$_sys_log_dir/$subdir" 2>/dev/null || true  # undoc-supp: system log subdir may not exist on first apply; best-effort ownership fix
    done
  fi
fi
