#!/usr/bin/env bash
# macos-symlink-farm.sh — Manage /usr/local/bin symlink farm for nixpkgs tools.
#
# Positional arguments:
#   $1  — space-separated "target->name" pairs (symlink farm entries)
#   $2  — path to verbose log (default: systemLogDir/symlink-farm.log)
#
# For each pair, create the symlink if it doesn't match.
# Remove any symlink in /usr/local/bin/ that points to a Nix store path
# but is NOT in the current farm (GC).
#
# Safety:
#   - Only operates on symlinks (-L), never touches regular files.
#   - Only GCs symlinks pointing to /nix/store/* (ignores non-Nix symlinks).
#   - Marker file (.nucleus-symlink-farm) is skipped during farm GC sweeps.
set -eu

FARM_DIR="/usr/local/bin"
FARM_MARKER=".nucleus-symlink-farm"

# Log file location.
NUCLEUS_SYSTEM_LOG_DIR="${NUCLEUS_SYSTEM_LOG_DIR:-/Users/Shared/nucleus/logs}"
LOG_FILE="${2:-$NUCLEUS_SYSTEM_LOG_DIR/symlink-farm.log}"
/bin/mkdir -p "$(dirname "$LOG_FILE")"

# Verbose mode: when set, detail echoes go to stdout too.
NUCLEUS_VERBOSE="${NUCLEUS_VERBOSE:-}"

_log() {
  printf '[%s] symlink-farm: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"
  if [ -n "$NUCLEUS_VERBOSE" ]; then
    printf 'symlink-farm: %s\n' "$*"
  fi
}

# Ensure farm directory exists
/bin/mkdir -p "$FARM_DIR"

# Parse current farm entries into an indexed array.
IFS=' ' read -r -a entries <<<"$1"

_created=0
for entry in "${entries[@]}"; do
  target="${entry%%->*}"
  link_name="${entry##*->}"
  link_path="$FARM_DIR/$link_name"

  if [ -L "$link_path" ]; then
    current_target="$(readlink "$link_path")"
    if [ "$current_target" = "$target" ]; then
      continue # already correct
    fi
  fi

  /bin/rm -f "$link_path"
  /bin/ln -s "$target" "$link_path"
  _log "$link_name → $target"
  _created=$((_created + 1))
done

# GC: remove /nix/store symlinks not in the active farm
_gc_count=0
for link_path in "$FARM_DIR"/*; do
  link_name="$(basename "$link_path")"
  [ "$link_name" = "$FARM_MARKER" ] && continue
  if [ -L "$link_path" ]; then
    target="$(readlink "$link_path")"
    if [[ "$target" == /nix/store/* ]]; then
      # Check if link_name is in the active entries list.
      _is_active=false
      for entry in "${entries[@]}"; do
        [ "${entry##*->}" = "$link_name" ] && {
          _is_active=true
          break
        }
      done
      if [ "$_is_active" = false ]; then
        /bin/rm "$link_path"
        _log "GC removed $link_name → $target"
        _gc_count=$((_gc_count + 1))
      fi
    fi
  fi
done

printf 'symlink-farm: %d active symlinks, %d GC'\''d (log: %s)\n' "$_created" "$_gc_count" "$LOG_FILE"
