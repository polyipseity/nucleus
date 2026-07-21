# Maintain exactly one BetterDisplay virtual screen named "HeadlessDisplay"
# and keep it connected for clamshell remote-desktop fallback.
#
# BetterDisplay free-tier constraint:
#   Runtime `set -connected=on` can fail without Pro on some builds, even
#   for virtual screens. To avoid paid-feature dependencies, this script
#   repairs state by recreating the virtual screen with `-connected=on`
#   instead of relying on connection toggles.
#
# Steps:
#   1. Launch BetterDisplay in the background if it is not already running.
#   2. Query BetterDisplay identifiers for `HeadlessDisplay`.
#   3. If there are zero/multiple instances, rebuild to one clean instance.
#   4. If the single instance exists but is disconnected, rebuild it.
#
# No-op if BetterDisplay is not installed.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
BD_APP="/Applications/BetterDisplay.app"
DISPLAY_NAME="HeadlessDisplay"

# _bd_cli args... -- Execute BetterDisplay CLI command, soft-fail on error.
_bd_cli() {
  # undoc-supp: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
  "$BD_BIN" "$@" || true
}

create_headless_display() {
  # Use documented virtual-screen parameters and force connected state at
  # creation time so fallback remains available with the lid closed.
  # Source: BetterDisplay CLI virtual-screen flags.
  # https://github.com/waydabber/BetterDisplay/wiki
  "$BD_BIN" create \
    -type=VirtualScreen \
    -virtualScreenName="$DISPLAY_NAME" \
    -aspectWidth=16 \
    -aspectHeight=10 \
    -multiplierStep=160 \
    -virtualScreenHiDPI=on \
    -connected=on
}

discard_headless_displays() {
  # Discard by BetterDisplay tag IDs so we only touch managed virtual
  # screens and avoid affecting physical monitors.
  for tag_id in $1; do
    if ! "$BD_BIN" discard -tagID="$tag_id"; then
      echo "macos: failed to discard duplicate BetterDisplay virtual screen tagID=$tag_id." >&2
    fi
  done
}

if [ -f "$BD_BIN" ]; then
  if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
    /usr/bin/open -g -a "$BD_APP"
    /bin/sleep 5  # wait for the app to initialise before issuing CLI commands
  fi

  identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
  tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
  tag_count="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"

  if [ "$tag_count" -ne 1 ]; then
    if [ "$tag_count" -gt 0 ]; then
      discard_headless_displays "$tag_ids"
    fi

    if ! create_headless_display; then
      echo "macos: failed to create BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
    fi
    /bin/sleep 3  # wait for the virtual display to be registered
    identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
    tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
  else
    tag_id="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { print; exit }')"
    connected_state="$(_bd_cli get -tagID="$tag_id" -connected)"

    if [ "$connected_state" != "on" ]; then
      if ! "$BD_BIN" discard -tagID="$tag_id"; then
        echo "macos: failed to discard disconnected BetterDisplay virtual screen '$DISPLAY_NAME' (tagID=$tag_id)." >&2
      fi

      if ! create_headless_display; then
        echo "macos: failed to recreate BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
      fi
      /bin/sleep 3  # wait for the virtual display to be registered
      identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
      tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
    fi
  fi

  connected_after="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"
  if [ "$connected_after" != "on" ]; then
    echo "macos: failed to set BetterDisplay virtual screen '$DISPLAY_NAME' connected=on." >&2
  fi
fi
