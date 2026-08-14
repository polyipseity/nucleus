#!/usr/bin/env bash
# Resolves a POSIX account homedir for a username.
set -euo pipefail

# Source lib.sh from this library's own directory (callers set SCRIPT_DIR to
# their own location, so resolve relative to this file).
_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$_LIB_DIR/lib.sh"
unset _LIB_DIR

resolve_user_homedir() {
  local username="$1"

  if [ -z "$username" ]; then
    warn -l resolve-user-homedir "username must be non-empty"
    return 1
  fi

  local homedir=""
  if command -v getent >/dev/null 2>&1; then
    homedir="$(getent passwd "$username" | awk -F: '{print $6}')"
  elif homedir="$(dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; then
    :
  elif [ -d "/Users/$username" ]; then
    homedir="/Users/$username"
  elif [ -d "/home/$username" ]; then
    homedir="/home/$username"
  fi

  if [ -n "$homedir" ] && [ -d "$homedir" ]; then
    printf '%s' "$homedir"
    return 0
  fi

  if [ "$username" = "$(id -un)" ] && [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    printf '%s' "$HOME"
    return 0
  fi

  warn -l resolve-user-homedir "could not resolve homedir for user '$username'"
  return 1
}

list_secret_users() {
  local repo_root="$1"
  local user_file username

  for user_file in "$repo_root"/src/secrets/users/*.yml; do
    [ -f "$user_file" ] || continue
    username="$(basename "$user_file" .yml)"
    printf '%s\n' "$username"
  done | LC_ALL=C sort
}
