#!/usr/bin/env bash
# macos-symlink-farm.sh - manage /usr/local/bin symlinks for nixpkgs tools.
#
# Positional arguments:
#   $1  space-separated "target->name" pairs
#   $2  verbose log path, default systemLogDir/symlink-farm.log
#   $FARM_DIR  farm directory override, default /usr/local/bin. Tests point
#              this at a temp dir; production never sets it.
#
# The GC sweep removes only symlinks into /nix/store that are not in the
# current farm. The create loop does replace a regular file occupying a
# managed link name, because a stale file there would block the symlink.
# The marker file is skipped during the sweep.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

FARM_DIR="${FARM_DIR:-/usr/local/bin}"
FARM_MARKER=".nucleus-symlink-farm"

NUCLEUS_SYSTEM_LOG_DIR="${NUCLEUS_SYSTEM_LOG_DIR:-/Library/Application Support/nucleus/logs}"
LOG_FILE="${2:-$NUCLEUS_SYSTEM_LOG_DIR/symlink-farm.log}"
/bin/mkdir -p "$(dirname "$LOG_FILE")"

NUCLEUS_VERBOSE="${NUCLEUS_VERBOSE:-}"

_log() {
  printf '[%s] symlink-farm: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
  if [ -n "$NUCLEUS_VERBOSE" ]; then
    say -l symlink-farm "$*"
  fi
}

/bin/mkdir -p "$FARM_DIR"

IFS=' ' read -r -a entries <<<"$1"

_active=0
_broken=0
for entry in "${entries[@]}"; do
  target="${entry%%->*}"
  link_name="${entry##*->}"
  link_path="$FARM_DIR/$link_name"

  if [ -L "$link_path" ]; then
    current_target="$(readlink "$link_path")"
    if [ "$current_target" = "$target" ]; then
      # WHY: the store path behind a matching link can be gone after a GC, so
      # resolve it. A dangling shim is a mapping bug, not a converged farm.
      if [ -e "$link_path" ]; then
        _active=$((_active + 1))
      else
        _broken=$((_broken + 1))
        warn -l symlink-farm "$link_name → $target does not exist; the mapping in apple-sdk-tools.nix points at a missing store path"
      fi
      continue
    fi
  fi

  /bin/rm -f "$link_path"
  /bin/ln -s "$target" "$link_path"
  _log "$link_name → $target"
  _active=$((_active + 1))
done

# GC: remove /nix/store symlinks not in the active farm
_gc_count=0
for link_path in "$FARM_DIR"/*; do
  link_name="$(basename "$link_path")"
  [ "$link_name" = "$FARM_MARKER" ] && continue
  if [ -L "$link_path" ]; then
    target="$(readlink "$link_path")"
    if [[ "$target" == /nix/store/* ]]; then
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

say -l symlink-farm "$_active active symlinks, $_gc_count GC'd, $_broken dangling (log: $LOG_FILE)"
