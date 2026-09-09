#!/usr/bin/env bash
# One-off migration: remove app-owned LaunchAgent plists and System Events
# login items, then create nucleus-owned plists via autostart.sh apply.
#
# Run once. Safe to re-run (idempotent).
# This script will be removed after migration.
#
# Usage: src/scripts/migrate-autostart-launchagent.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
case "${1:-}" in
--dry-run) DRY_RUN=true ;;
esac

LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"

# App-owned LaunchAgent plists to remove (bundleId → app path for safety check).
# Only apps that have startAtLogin/LaunchAtLogin create these.
declare -A APP_PLISTS=(
  ["com.lwouis.alt-tab-macos"]="/Applications/AltTab.app"
  ["com.raycast.macos"]="/Applications/Raycast.app"
  ["pro.betterdisplay.BetterDisplay"]="/Applications/BetterDisplay.app"
  ["com.lujjjh.LinearMouse"]="/Applications/LinearMouse.app"
)

# System Events login item names to remove.
LOGIN_ITEMS=(
  "Raycast"
  "Amphetamine"
  "Stats"
  "BetterDisplay"
  "MiddleClick"
  "Mounty"
  "LinearMouse"
  "LuLu"
  "OrbStack"
  "Parsec"
  "Telegram"
  "WhatsApp"
  "Steam"
  "AltTab"
  "battery"
  "Rectangle"
  "Discord"
  "Discord Canary"
)

removed=0

# --- 1. Remove app-owned LaunchAgent plists ---
for bundle_id in "${!APP_PLISTS[@]}"; do
  app_path="${APP_PLISTS[$bundle_id]}"
  plist="$LAUNCHAGENTS_DIR/${bundle_id}.plist"
  if [ -f "$plist" ]; then
    if $DRY_RUN; then
      echo "[dry-run] would remove $plist"
    else
      rm -f "$plist"
      echo "removed $plist"
    fi
    removed=$((removed + 1))
  fi
done

# --- 2. Best-effort remove System Events login items ---
for name in "${LOGIN_ITEMS[@]}"; do
  if $DRY_RUN; then
    echo "[dry-run] would remove System Events login item '$name'"
  else
    osascript \
      -e 'tell application "System Events"' \
      -e "if exists login item \"$name\" then" \
      -e "delete login item \"$name\"" \
      -e 'end if' \
      -e 'end tell' 2>/dev/null || true # check-suppress:suppression_doc: osascript fails on macOS 26; best-effort cleanup.
  fi
done

echo ""
echo "Removed $removed app-owned plists."

if ! $DRY_RUN; then
  echo ""
  SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
  echo "Running autostart.sh apply..."
  "$SCRIPT_DIR/autostart.sh" apply
  echo ""
  echo "Final state:"
  "$SCRIPT_DIR/autostart.sh" list
fi
