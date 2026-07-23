#!/usr/bin/env bash
# Create system log directories for all nucleus systemd/launchd services before
# they start, so journald/stderr redirect targets exist on disk.

set -euo pipefail


_sys_log_dir="$1"
_log_subdirs="$2"
if [ -n "$_sys_log_dir" ]; then
  for subdir in $_log_subdirs; do
    mkdir -p "$_sys_log_dir/$subdir"
  done
fi

# macOS-specific: create user-level log dirs in ~/Library/Logs/nucleus/ and
# chown system log subdirs to the console user so launchd can write.
_user_log_subdirs="$3"
_chown_log_subdirs="$4"
if [ "$(uname -s)" = "Darwin" ] && [ -n "$_user_log_subdirs" ]; then
  _console_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"  # check-suppress:suppression_doc: /dev/console may not exist in headless/SSH sessions
  if [ -n "$_console_user" ] && [ "$_console_user" != "/Users/root" ]; then
    _username="${_console_user#/Users/}"
    for subdir in $_user_log_subdirs; do
      /bin/mkdir -p "$_console_user/Library/Logs/nucleus/$subdir"
    done
    /usr/sbin/chown -R "$_username:staff" "$_console_user/Library/Logs/nucleus"

    for subdir in $_chown_log_subdirs; do
      /usr/sbin/chown "$_username:staff" "$_sys_log_dir/$subdir" 2>/dev/null || true  # check-suppress:suppression_doc: system log subdir may not exist on first apply; best-effort ownership fix
    done
  fi
fi
