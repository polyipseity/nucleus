#!/usr/bin/env bash
# One-off migration: replace System Events login items with LaunchAgent plists.
#
# This script removes app-owned LaunchAgent plists (e.g. AltTab's startAtLogin
# plist) and best-effort removes System Events login items, then runs
# autostart.sh apply to create nucleus-owned plists.
#
# Run once. Idempotent — safe to re-run if interrupted.
#
# Usage: src/scripts/migrate-autostart-launchagent.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib/lib.sh"

REPO_ROOT="$(derive_repo_root)"
APPS_JSON="$REPO_ROOT/src/modules/apps.json"
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
DRY_RUN=false

case "${1:-}" in
--dry-run) DRY_RUN=true ;;
esac

if [ ! -f "$APPS_JSON" ]; then
  die "apps.json not found at $APPS_JSON"
fi

require_command jq

# Collect login-item apps with bundleId from apps.json.
mapfile -t apps < <(
  jq -r '
    to_entries[]
    | select(.value | type == "object")
    | select(.value.hosts.MacBook.kind == "login-item")
    | select(.value.hosts.MacBook.bundleId != null and .value.hosts.MacBook.bundleId != "N/A")
    | [.value.hosts.MacBook.bundleId, .value.hosts.MacBook.path, .key] | @tsv
  ' "$APPS_JSON"
)

removed=0
skipped=0

for entry in "${apps[@]}"; do
  IFS=$'\t' read -r bundle_id app_path app_name <<< "$entry"

  # --- 1. Remove app-owned LaunchAgent plist ---
  app_plist="$LAUNCHAGENTS_DIR/${bundle_id}.plist"
  if [ -f "$app_plist" ]; then
    # Safety: extract Program field and verify it matches the app path.
    plist_program=$(sed -n '/<key>ProgramArguments</key>/,/<\/array>/p' "$app_plist" \
      | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1)
    if [ "$plist_program" = "$app_path" ]; then
      if $DRY_RUN; then
        echo "[dry-run] would remove $app_plist"
      else
        rm -f "$app_plist"
        echo "removed $app_plist (matched $app_path)"
      fi
      ((removed++))
    else
      echo "skip $app_plist — Program mismatch: '$plist_program' != '$app_path'"
      ((skipped++))
    fi
  fi

  # --- 2. Best-effort remove System Events login item ---
  if $DRY_RUN; then
    echo "[dry-run] would remove System Events login item '$app_name'"
  else
    osascript \
      -e 'tell application "System Events"' \
      -e "if exists login item \"$app_name\" then" \
      -e "delete login item \"$app_name\"" \
      -e 'end if' \
      -e 'end tell' 2>/dev/null || true # check-suppress:suppression_doc: osascript fails on macOS 26 (error -10810); best-effort cleanup.
  fi

  # --- 3. Best-effort remove embedded helper login items ---
  if [ -d "$app_path/Contents/Library/LoginItems" ]; then
    if $DRY_RUN; then
      echo "[dry-run] would remove embedded login items in $app_path/Contents/Library/LoginItems/"
    else
      osascript \
        -e 'tell application "System Events"' \
        -e "set liPrefix to \"$app_path/Contents/Library/LoginItems\"" \
        -e 'repeat with li in login items' \
        -e 'try' \
        -e 'set liPath to path of li' \
        -e 'on error' \
        -e 'set liPath to ""' \
        -e 'end try' \
        -e 'if liPath starts with liPrefix then' \
        -e 'delete li' \
        -e 'end if' \
        -e 'end repeat' \
        -e 'end tell' 2>/dev/null || true # check-suppress:suppression_doc: osascript fails on macOS 26; best-effort cleanup.
    fi
  fi
done

echo ""
echo "Migration complete: $removed app-owned plists removed, $skipped skipped."

if ! $DRY_RUN; then
  echo ""
  echo "Running autostart.sh apply to create nucleus-owned plists..."
  "$SCRIPT_DIR/autostart.sh" apply
  echo ""
  echo "Current state:"
  "$SCRIPT_DIR/autostart.sh" list
fi
