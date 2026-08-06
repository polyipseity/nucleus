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

# macOS-specific: create user-level log dirs under ~/nucleus/logs and
# chown system log subdirs to the console user so launchd can write.
_user_log_root="${5:-}"
_user_log_subdirs="$3"
_chown_log_subdirs="$4"
if [ "$(uname -s)" = "Darwin" ] && [ -n "$_user_log_subdirs" ]; then
  _console_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"  # check-suppress:suppression_doc: /dev/console may not exist in headless/SSH sessions
  if [ -n "$_console_user" ] && [ "$_console_user" != "/Users/root" ]; then
    _username="${_console_user#/Users/}"
    if [ -z "$_user_log_root" ]; then
      _user_log_root="${_console_user}/nucleus/logs"
    elif [ "${_user_log_root#\~/}" != "$_user_log_root" ]; then
      _user_log_root="${_console_user}${_user_log_root#~}"
    fi
    for subdir in $_user_log_subdirs; do
      /bin/mkdir -p "$_user_log_root/$subdir"
    done
    /usr/sbin/chown -R "$_username:staff" "$_user_log_root"

    for subdir in $_chown_log_subdirs; do
      /usr/sbin/chown "$_username:staff" "$_sys_log_dir/$subdir" 2>/dev/null || true  # check-suppress:suppression_doc: system log subdir may not exist on first apply; best-effort ownership fix
    done
  fi
fi
