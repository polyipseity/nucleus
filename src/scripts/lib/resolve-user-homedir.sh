#!/usr/bin/env bash
# Resolves a POSIX account homedir for a username.
set -euo pipefail

resolve_user_homedir() {
  local username="$1"

  if [ -z "$username" ]; then
    echo "resolve-user-homedir: username must be non-empty" >&2
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

  echo "resolve-user-homedir: could not resolve homedir for user '$username'" >&2
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
