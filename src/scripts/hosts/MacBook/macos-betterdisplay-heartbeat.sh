# BetterDisplay virtual screen heartbeat.  Polls the HeadlessDisplay every 30
# seconds and reconnects it if BetterDisplay marks it as disconnected.
#
# Environment variables (with built-in defaults):
#   BD_BIN  — path to BetterDisplay executable
#   BD_APP  — path to BetterDisplay .app bundle
#   DISPLAY_NAME — virtual display name to monitor

set +e  # heartbeat is fully soft-fail; never abort on individual check failure

: "${BD_BIN:=/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}" \
  "${BD_APP:=/Applications/BetterDisplay.app}" \
  "${DISPLAY_NAME:=HeadlessDisplay}"

# _bd_cli args... — Execute BetterDisplay CLI command, soft-fail on error.
_bd_cli() {
  # undoc-supp: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
  "$BD_BIN" "$@" || true
}

# Persistent daemon loop: check every 30 s.
while true; do
  # No-op if BetterDisplay is not installed.
  if [ ! -f "$BD_BIN" ]; then
    sleep 30
    continue
  fi

  # Ensure BetterDisplay is running before issuing CLI commands.
  if ! /usr/bin/pgrep -xq "BetterDisplay" 2>/dev/null; then
    # undoc-supp: BetterDisplay may not be installed yet; best-effort launch.
    /usr/bin/open -g -a "$BD_APP" || true
    /bin/sleep 5
  fi

  # Check connection state; soft-fail by treating any CLI error as unknown.
  connected_state="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"

  # No-op if already connected.
  if [ "$connected_state" = "on" ]; then
    sleep 30
    continue
  fi

  # Virtual screen is disconnected or status is unknown.  Try the lightweight
  # set -connected=on toggle first; it is free-tier-compatible for virtual
  # screens (Pro gating applies only to physical display connection toggles).
  # If the toggle fails, fall back to a discard-and-recreate using the same
  # parameters as macos-headless-display so the virtual screen specification
  # stays consistent across both code paths.
  if ! "$BD_BIN" set -name="$DISPLAY_NAME" -connected=on; then
    tag_ids="$(_bd_cli get -identifiers -name="$DISPLAY_NAME" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
    for tag_id in $tag_ids; do
      _bd_cli discard -tagID="$tag_id"
    done
    _bd_cli create \
      -type=VirtualScreen \
      -virtualScreenName="$DISPLAY_NAME" \
      -aspectWidth=16 \
      -aspectHeight=10 \
      -multiplierStep=160 \
      -virtualScreenHiDPI=on \
      -connected=on
  fi

  sleep 30
done
