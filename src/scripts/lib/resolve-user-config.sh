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
  candidate="$(CDPATH='' cd -- "$script_dir/../../.." && pwd -P)"
  if [ -f "$candidate/src/flake.nix" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  echo "resolve-user-config: NUCLEUS_REPO_ROOT is not set and repo root could not be derived" >&2
  return 1
}

_resolve_user_config_first_level_entry() {
  local username="$1"
  local config_name="$2"
  local entry_name="$3"
  local repo_root per_user default

  repo_root="$(_resolve_user_config_repo_root)"
  per_user="${repo_root}/src/users/${username}/${config_name}/${entry_name}"
  default="${repo_root}/src/users/default/${config_name}/${entry_name}"

  if [ -e "$per_user" ] || [ -L "$per_user" ]; then
    printf '%s' "$per_user"
    return 0
  fi
  if [ -e "$default" ] || [ -L "$default" ]; then
    printf '%s' "$default"
    return 0
  fi

  echo "resolve_user_config_first_level_entry: no source for user '$username' config '$config_name' entry '$entry_name'" >&2
  return 1
}

_list_user_config_seen_entry() {
  local candidate="$1"
  local seen_entry

  for seen_entry in ${_luc_seen_entries+"${_luc_seen_entries[@]}"}; do
    if [ "$seen_entry" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

list_user_config_first_level_entries() {
  local username="$1"
  local config_name="$2"
  local repo_root per_user_dir default_dir entry entry_name
  _luc_seen_entries=()

  repo_root="$(_resolve_user_config_repo_root)"
  per_user_dir="${repo_root}/src/users/${username}/${config_name}"
  default_dir="${repo_root}/src/users/default/${config_name}"

  for entry in "$per_user_dir"/* "$default_dir"/*; do
    [ -e "$entry" ] || continue
    entry_name="$(basename "$entry")"
    if _list_user_config_seen_entry "$entry_name"; then
      continue
    fi
    _luc_seen_entries+=("$entry_name")
    printf '%s\n' "$entry_name"
  done
}

resolve_user_config_file() {
  local username="$1"
  local config_name="$2"
  local relative_path="$3"
  local first_segment rest_path entry_root resolved

  first_segment="${relative_path%%/*}"
  if [ "$first_segment" = "$relative_path" ]; then
    rest_path=""
  else
    rest_path="${relative_path#*/}"
  fi

  entry_root="$(_resolve_user_config_first_level_entry "$username" "$config_name" "$first_segment")"
  if [ -z "$rest_path" ]; then
    resolved="$entry_root"
  else
    resolved="${entry_root}/${rest_path}"
  fi

  if [ -e "$resolved" ] || [ -L "$resolved" ]; then
    printf '%s' "$resolved"
    return 0
  fi

  echo "resolve_user_config_file: no source for user '$username' config '$config_name' path '$relative_path' (resolved '$resolved')" >&2
  return 1
}

resolve_user_config_first_level_entry() {
  _resolve_user_config_first_level_entry "$@"
}

_wallpaper_image_name() {
  case "${1,,}" in
  *.gif | *.jpeg | *.jpg | *.png | *.webp) return 0 ;;
  *) return 1 ;;
  esac
}

list_wallpaper_encrypted_blobs() {
  local username="$1"
  local encrypted_dir entry base

  encrypted_dir="$(resolve_user_config_first_level_entry "$username" "wallpapers" "encrypted")"
  for entry in "$encrypted_dir"/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
    *.sops) printf '%s\n' "$base" ;;
    esac
  done
}

list_wallpaper_unencrypted_files() {
  local username="$1"
  local wallpapers_dir entry base

  wallpapers_dir="$(resolve_user_config_first_level_entry "$username" "wallpapers" "wallpapers")"
  for entry in "$wallpapers_dir"/*; do
    [ -f "$entry" ] || continue
    base="$(basename "$entry")"
    if _wallpaper_image_name "$base"; then
      printf '%s\n' "$base"
    fi
  done
}

resolve_wallpaper_encrypted_blob() {
  resolve_user_config_file "$1" "wallpapers" "encrypted/$2"
}

resolve_wallpaper_unencrypted_file() {
  resolve_user_config_file "$1" "wallpapers" "wallpapers/$2"
}
