#!/usr/bin/env bash
# Set the boolean "systemTray" key in Discord's settings.json.
#
# WHY this must run while Discord is closed: Discord rewrites settings.json on
# launch and would drop the change. Activation runs before the app opens.
#
# Usage: discord-tray.sh <visible> [appKey]
#   visible: true|false, also 1/0/visible/hidden/show/hide
#   appKey:  Discord (stable) or a Canary variant; defaults to stable.

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
