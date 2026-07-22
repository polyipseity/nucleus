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
#   - Marker file (.nucleus-symlink-farm) identifies farm-managed state.
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
  printf '[%s] symlink-farm: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
  [ -n "$NUCLEUS_VERBOSE" ] && printf 'symlink-farm: %s\n' "$*"
}

# Ensure farm directory exists
/bin/mkdir -p "$FARM_DIR"

# If marker doesn't exist, sweep all stale Nix store symlinks (first-run GC).
if [ ! -f "$FARM_DIR/$FARM_MARKER" ]; then
  _gc_count=0
  for link in "$FARM_DIR"/*; do
    if [ -L "$link" ]; then
      target="$(readlink "$link")"
      case "$target" in
        /nix/store/*)
          /bin/rm "$link"
          _log "first-run GC removed $link → $target"
          _gc_count=$((_gc_count + 1))
          ;;
      esac
    fi
  done
  if [ "$_gc_count" -gt 0 ]; then
    _log "first-run GC complete: $_gc_count symlinks removed"
  fi
  : > "$FARM_DIR/$FARM_MARKER"
fi

# Parse current farm entries into an associative array.
# Bash <4 doesn't support declare -A, but macOS 26 ships Bash 5+.
declare -A active_symlinks
IFS=' ' read -r -a entries <<< "$1"

_created=0
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
    if [[ "$target" == /nix/store/* ]] && [[ -z "${active_symlinks[$link_name]:-}" ]]; then
      /bin/rm "$link_path"
      _log "GC removed $link_name → $target"
      _gc_count=$((_gc_count + 1))
    fi
  fi
done

printf 'symlink-farm: %d active symlinks, %d GC'\''d (log: %s)\n' "$_created" "$_gc_count" "$LOG_FILE"
