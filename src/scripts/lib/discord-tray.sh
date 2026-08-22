#!/usr/bin/env bash
# Converge Discord's system-tray icon visibility by editing its settings.json.
# Discord rewrites settings.json on launch, so this must run while Discord is
# closed (activation runs at login/apply, before the app opens — acceptable).
#
# Usage: discord-tray.sh <visible> [appKey]
#   visible: true|false (case-insensitive; also accepts 1/0/visible/hidden)
#   appKey:  "Discord" (stable) or "Discord Canary" (canary); defaults to stable.
#
# Edits ~/.config/discord/settings.json (stable) or
# ~/.config/discordcanary/settings.json (canary), setting the boolean
# "systemTray" key. Idempotent.

set -euo pipefail

case "${1:-}" in
true | True | 1 | visible | show) VISIBLE=true ;;
false | False | 0 | hidden | hide) VISIBLE=false ;;
*)
  echo "discord-tray.sh: invalid visible arg '${1:-}'" >&2
  exit 2
  ;;
esac

APP_KEY="${2:-Discord}"
case "$APP_KEY" in
*[Cc]anary*) CONFIG_DIR="$HOME/.config/discordcanary" ;;
*) CONFIG_DIR="$HOME/.config/discord" ;;
esac

CONFIG="$CONFIG_DIR/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "discord-tray.sh: jq required" >&2
  exit 3
fi

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG" ]; then
  echo '{}' >"$CONFIG"
fi

CURRENT="$(jq -r '.systemTray // empty' "$CONFIG" 2>/dev/null || true)" # check-suppress:suppression_doc: tolerate missing/unreadable config; treated as not-yet-set.
if [ "$CURRENT" = "$VISIBLE" ]; then
  exit 0
fi

TMP="$(mktemp)"
jq --argjson v "$VISIBLE" '.systemTray = $v' "$CONFIG" >"$TMP"
mv "$TMP" "$CONFIG"
exit 0
