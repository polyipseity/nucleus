#!/usr/bin/env bash
# Create English-named .app symlink aliases for Raycast compatibility
# on non-English macOS installations.
#
# Requires _nucleus_protect_symlink and _nucleus_unprotect_symlink (self-sourced below).
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
. "$SCRIPT_DIR/../../../scripts/lib/symlink-hardening.sh"

_ray_alias_dir="$HOME/Applications/Nucleus App Aliases"
mkdir -p "$_ray_alias_dir"

ensure_alias() {
  _alias_name="$1"
  _target_app="$2"
  _alias_path="$_ray_alias_dir/$_alias_name"

  [ -e "$_target_app" ] || return 0

  if [ -L "$_alias_path" ]; then
    if [ "$(readlink "$_alias_path")" = "$_target_app" ]; then
      _nucleus_protect_symlink "raycast" "$_alias_path"
      return 0
    fi
    _nucleus_unprotect_symlink "raycast" "$_alias_path"
    rm "$_alias_path"
  elif [ -e "$_alias_path" ]; then
    warn "keeping unmanaged app alias path $_alias_path (not a symlink)."
    return 0
  fi

  ln -s "$_target_app" "$_alias_path"
  _nucleus_protect_symlink "raycast" "$_alias_path"
}

ensure_alias "Books (English).app" "/System/Applications/Books.app"
ensure_alias "Calculator (English).app" "/System/Applications/Calculator.app"
ensure_alias "Calendar (English).app" "/System/Applications/Calendar.app"
ensure_alias "Contacts (English).app" "/System/Applications/Contacts.app"
ensure_alias "FaceTime (English).app" "/System/Applications/FaceTime.app"
ensure_alias "Find My (English).app" "/System/Applications/FindMy.app"
ensure_alias "Freeform (English).app" "/System/Applications/Freeform.app"
ensure_alias "Home (English).app" "/System/Applications/Home.app"
ensure_alias "Mail (English).app" "/System/Applications/Mail.app"
ensure_alias "Maps (English).app" "/System/Applications/Maps.app"
ensure_alias "Messages (English).app" "/System/Applications/Messages.app"
ensure_alias "Music (English).app" "/System/Applications/Music.app"
ensure_alias "Notes (English).app" "/System/Applications/Notes.app"
ensure_alias "Photos (English).app" "/System/Applications/Photos.app"
ensure_alias "Reminders (English).app" "/System/Applications/Reminders.app"
ensure_alias "Safari (English).app" "/Applications/Safari.app"
ensure_alias "TV (English).app" "/System/Applications/TV.app"
ensure_alias "Weather (English).app" "/System/Applications/Weather.app"
