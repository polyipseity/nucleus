#!/usr/bin/env bash
# Maintain exactly one BetterDisplay virtual screen named "HeadlessDisplay"
# and keep it connected for clamshell remote-desktop fallback.
#
# WHY: runtime `set -connected=on` can fail without Pro on some builds, even for
# virtual screens, so the screen is recreated with `-connected=on` rather than
# toggled. No-op if BetterDisplay is not installed.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
BD_APP="/Applications/BetterDisplay.app"
DISPLAY_NAME="HeadlessDisplay"

# _bd_cli args... -- Execute BetterDisplay CLI command, soft-fail on error.
_bd_cli() {
  # check-suppress:suppression_doc: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
  "$BD_BIN" "$@" || true
}

create_headless_display() {
  # WHY: the flags come from the BetterDisplay CLI virtual-screen docs.
  # https://github.com/waydabber/BetterDisplay/wiki
  # multiplierStep x aspect is the logical size and -virtualScreenHiDPI doubles
  # it into the framebuffer: 80 x 16:10 = 1280x800 logical / 2560x1600
  # framebuffer, matching the built-in display's logical size so a remote
  # session sees the same layout. macos-heartbeat-betterdisplay.sh passes the
  # same value and macos-headless-display-tests.sh fails if the two drift.
  "$BD_BIN" create \
    -type=VirtualScreen \
    -virtualScreenName="$DISPLAY_NAME" \
    -aspectWidth=16 \
    -aspectHeight=10 \
    -multiplierStep=80 \
    -virtualScreenHiDPI=on \
    -connected=on
}

discard_headless_displays() {
  # Discard by tag ID so only managed virtual screens are touched.
  for tag_id in $1; do
    if ! "$BD_BIN" discard -tagID="$tag_id"; then
      die "failed to discard duplicate BetterDisplay virtual screen tagID=$tag_id."
    fi
  done
}

if [ -f "$BD_BIN" ]; then
  if ! /usr/bin/pgrep -x "BetterDisplay" >/dev/null; then
    /usr/bin/open -g -a "$BD_APP"
    /bin/sleep 5 # wait for the app to initialise before issuing CLI commands
  fi

  identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
  tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
  tag_count="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"

  if [ "$tag_count" -ne 1 ]; then
    if [ "$tag_count" -gt 0 ]; then
      discard_headless_displays "$tag_ids"
    fi

    if ! create_headless_display; then
      die "failed to create BetterDisplay virtual screen '$DISPLAY_NAME'."
    fi
    /bin/sleep 3 # wait for the virtual display to be registered
    identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
    tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
  else
    tag_id="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { print; exit }')"
    connected_state="$(_bd_cli get -tagID="$tag_id" -connected)"

    if [ "$connected_state" != "on" ]; then
      if ! "$BD_BIN" discard -tagID="$tag_id"; then
        die "failed to discard disconnected BetterDisplay virtual screen '$DISPLAY_NAME' (tagID=$tag_id)."
      fi

      if ! create_headless_display; then
        die "failed to recreate BetterDisplay virtual screen '$DISPLAY_NAME'."
      fi
      /bin/sleep 3 # wait for the virtual display to be registered
      identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
      tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
    fi
  fi

  connected_after="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"
  if [ "$connected_after" != "on" ]; then
    die "failed to set BetterDisplay virtual screen '$DISPLAY_NAME' connected=on."
  fi
fi
