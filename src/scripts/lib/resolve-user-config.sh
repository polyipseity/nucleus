#!/usr/bin/env bash
# Resolves per-user homedir overlay paths. Mirrors users-overlay.nix.
set -euo pipefail

_resolve_user_config_repo_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ]; then
    printf '%s' "$NUCLEUS_REPO_ROOT"
    return 0
  fi

  local script_dir
  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local candidate
  candidate="$(CDPATH='' cd -- "$script_dir/../../../.." && pwd -P)"
  if [ -f "$candidate/src/flake.nix" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  echo "resolve-user-config: NUCLEUS_REPO_ROOT is not set and repo root could not be derived" >&2
  return 1
}

resolve_user_config_file() {
  local username="$1"
  local config_name="$2"
  local relative_path="$3"
  local repo_root per_user default

  repo_root="$(_resolve_user_config_repo_root)"
  per_user="${repo_root}/src/users/${username}/${config_name}/${relative_path}"
  default="${repo_root}/src/users/default/${config_name}/${relative_path}"

  if [ -f "$per_user" ]; then
    printf '%s' "$per_user"
    return 0
  fi
  if [ -f "$default" ]; then
    printf '%s' "$default"
    return 0
  fi

  echo "resolve_user_config_file: no source for user '$username' config '$config_name' path '$relative_path'" >&2
  return 1
}

resolve_user_config_dir() {
  local username="$1"
  local config_name="$2"
  local repo_root per_user default

  repo_root="$(_resolve_user_config_repo_root)"
  per_user="${repo_root}/src/users/${username}/${config_name}"
  default="${repo_root}/src/users/default/${config_name}"

  if [ -d "$per_user" ]; then
    printf '%s' "$per_user"
    return 0
  fi
  if [ -d "$default" ]; then
    printf '%s' "$default"
    return 0
  fi

  echo "resolve_user_config_dir: no source for user '$username' config '$config_name'" >&2
  return 1
}
