#!/usr/bin/env bash
# Create nucleus log directories for all services before they start, so stderr/stdout
# capture targets and service log files exist on disk.
#
# Args:
#   1  system log root
#   2  system log subdirs
#   3  user log subdirs
#   4  system log subdirs to chown to the user
#   5  user log root, may start with ~ (defaults to <home>/nucleus/logs)
#   6  user home dir (required off macOS)
#   7  owner of the user log dirs, as user:group (required off macOS)

set -euo pipefail

_sys_log_dir="$1"
_sys_log_subdirs="$2"
_user_log_subdirs="$3"
_chown_log_subdirs="$4"
_user_log_root="${5:-}"
_user_log_home="${6:-}"
_user_log_owner="${7:-}"

if [ -n "$_sys_log_dir" ]; then
  for subdir in $_sys_log_subdirs; do
    mkdir -p "$_sys_log_dir/$subdir"
  done
fi

# User-level log dirs. macOS activation may run before anyone has logged in, so the
# console user — not $HOME, which is root's — supplies the home dir and the owner. Linux
# is handed both explicitly for the same reason: nixos-rebuild activation runs as root
# and there is no console user to infer from.
if [ -n "$_user_log_subdirs" ]; then
  _user_log_ready=false
  if [ "$(uname -s)" = "Darwin" ]; then
    _console_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)" # check-suppress:suppression_doc: /dev/console may not exist in headless/SSH sessions
    if [ -n "$_console_user" ] && [ "$_console_user" != "/Users/root" ]; then
      _user_log_home="$_console_user"
      _user_log_owner="${_console_user#/Users/}:staff"
      _user_log_ready=true
    fi
    # No console user (headless/SSH): leave this to the next apply that has one.
  elif [ -n "$_user_log_home" ] && [ -n "$_user_log_owner" ]; then
    _user_log_ready=true
  else
    echo "log-dirs-init: user log dirs requested but no user home/owner given" >&2
    exit 1
  fi

  if [ "$_user_log_ready" = true ]; then
    if [ -z "$_user_log_root" ]; then
      _user_log_root="$_user_log_home/nucleus/logs"
    elif [ "${_user_log_root#\~/}" != "$_user_log_root" ]; then
      _user_log_root="$_user_log_home/${_user_log_root#\~/}"
    elif [ "${_user_log_root#/}" = "$_user_log_root" ]; then
      _user_log_root="$_user_log_home/$_user_log_root"
    fi
    for subdir in $_user_log_subdirs; do
      mkdir -p "$_user_log_root/$subdir"
    done
    chown -R "$_user_log_owner" "$_user_log_root"

    for subdir in $_chown_log_subdirs; do
      chown "$_user_log_owner" "$_sys_log_dir/$subdir" 2>/dev/null || true # check-suppress:suppression_doc: system log subdir may not exist on first apply; best-effort ownership fix
    done
  fi
fi
