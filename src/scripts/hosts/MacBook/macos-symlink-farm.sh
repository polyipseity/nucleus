#!/usr/bin/env bash
# macos-symlink-farm.sh — Manage /usr/local/bin symlink farm for nixpkgs tools.
#
# Environment variables (set by Nix wrapper in activation.nix):
#   __nucleus_symlink_farm  — space-separated "target->name" pairs
#
# For each pair, create the symlink if it doesn't match.
# Remove any symlink in /usr/local/bin/ that points to a Nix store path
# but is NOT in the current farm (GC).
#
# Safety:
#   - Only operates on symlinks (-L), never touches regular files.
#   - Only GCs symlinks pointing to /nix/store/* (ignores non-Nix symlinks).
#   - Marker file (.nucleus-symlink-farm) identifies farm-managed state.
set -eu

FARM_DIR="/usr/local/bin"
FARM_MARKER=".nucleus-symlink-farm"

# Ensure farm directory exists
/bin/mkdir -p "$FARM_DIR"

# If marker doesn't exist, sweep all stale Nix store symlinks (first-run GC).
if [ ! -f "$FARM_DIR/$FARM_MARKER" ]; then
  for link in "$FARM_DIR"/*; do
    if [ -L "$link" ]; then
      target="$(readlink "$link")"
      case "$target" in
        /nix/store/*)
          /bin/rm "$link"
          echo "symlink-farm: first-run GC removed $link → $target"
          ;;
      esac
    fi
  done
  : > "$FARM_DIR/$FARM_MARKER"
fi

# Parse current farm entries into an associative array.
# Bash <4 doesn't support declare -A, but macOS 26 ships Bash 5+.
declare -A active_symlinks
IFS=' ' read -r -a entries <<< "$__nucleus_symlink_farm"

for entry in "${entries[@]}"; do
  target="${entry%%->*}"
  link_name="${entry##*->}"
  link_path="$FARM_DIR/$link_name"

  active_symlinks[$link_name]=1

  if [ -L "$link_path" ]; then
    current_target="$(readlink "$link_path")"
    if [ "$current_target" = "$target" ]; then
      continue  # already correct
    fi
  fi

  /bin/rm -f "$link_path"
  /bin/ln -s "$target" "$link_path"
  echo "symlink-farm: $link_name → $target"
done

# GC: remove /nix/store symlinks not in the active farm
for link_path in "$FARM_DIR"/*; do
  link_name="$(basename "$link_path")"
  [ "$link_name" = "$FARM_MARKER" ] && continue
  if [ -L "$link_path" ]; then
    target="$(readlink "$link_path")"
    if [[ "$target" == /nix/store/* ]] && [[ -z "${active_symlinks[$link_name]:-}" ]]; then
      /bin/rm "$link_path"
      echo "symlink-farm: GC removed $link_name → $target"
    fi
  fi
done
