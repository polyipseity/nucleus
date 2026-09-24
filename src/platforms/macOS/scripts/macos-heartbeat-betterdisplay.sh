#!/usr/bin/env bash
# BetterDisplay virtual screen heartbeat.  Polls the HeadlessDisplay every 60
# seconds and reconnects it if BetterDisplay marks it as disconnected.
# Uses svc_health for restart tracking; loop detection is handled by the
# watchdog via svc_health_is_looping.
#
# Environment variables (with built-in defaults):
#   BD_BIN  — path to BetterDisplay executable
#   BD_APP  — path to BetterDisplay .app bundle
#   DISPLAY_NAME — virtual display name to monitor

set +e # heartbeat is fully soft-fail; never abort on individual check failure

# Source service-health and bounded-execution libraries.
_BD_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/service-health.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/service-health.sh"
# shellcheck source=../../../scripts/lib/svc-instances.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/svc-instances.sh"

: "${BD_BIN:=/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}" \
  "${BD_APP:=/Applications/BetterDisplay.app}" \
  "${DISPLAY_NAME:=HeadlessDisplay}"

# _bd_cli args... — Execute BetterDisplay CLI command, soft-fail on error.
_bd_cli() {
  # check-suppress:suppression_doc: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
  svc_run_bounded 10 "$BD_BIN" "$@" || true
}

# Persistent daemon loop: check every 60 s. _bd_connected_prev tracks the last
# observed connection state so a healthy tick is recorded once, not every tick.
_bd_connected_prev=""
while true; do
  # No-op if BetterDisplay is not installed.
  if [ ! -f "$BD_BIN" ]; then
    sleep 60
    continue
  fi

  # Ensure BetterDisplay is running before issuing CLI commands.
  if ! /usr/bin/pgrep -xq "BetterDisplay" 2>/dev/null; then
    # No App Store receipt pre-flight here on purpose: this host installs
    # BetterDisplay from the Homebrew cask (src/hosts/MacBook/homebrew.nix),
    # which ships no Contents/_MASReceipt. A receipt guard would therefore block
    # the relaunch path permanently instead of guarding it.

    # check-suppress:suppression_doc: BetterDisplay may not be installed yet; best-effort launch.
    /usr/bin/open -g -a "$BD_APP" || true
    svc_health_record_restart "betterdisplay-heartbeat" "relaunch"
    /bin/sleep 5
  fi

  # Check connection state; soft-fail by treating any CLI error as unknown.
  connected_state="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"

  # No-op if already connected. Success is recorded only when the display has
  # just become connected: it marks the start of a healthy period.
  if [ "$connected_state" = "on" ]; then
    if [ "$_bd_connected_prev" != "on" ]; then
      svc_health_record_success "betterdisplay-heartbeat"
      _bd_connected_prev="on"
    fi
    sleep 60
    continue
  fi
  _bd_connected_prev=""

  # Virtual screen is disconnected or status is unknown.  Try the lightweight
  # set -connected=on toggle first; it is free-tier-compatible for virtual
  # screens (Pro gating applies only to physical display connection toggles).
  # If the toggle fails, fall back to a discard-and-recreate using the same
  # parameters as macos-headless-display so the virtual screen specification
  # stays consistent across both code paths.
  if ! svc_run_bounded 10 "$BD_BIN" set -name="$DISPLAY_NAME" -connected=on; then
    tag_ids="$(_bd_cli get -identifiers -name="$DISPLAY_NAME" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
    for tag_id in $tag_ids; do
      _bd_cli discard -tagID="$tag_id"
    done
    _bd_cli create \
      -type=VirtualScreen \
      -virtualScreenName="$DISPLAY_NAME" \
      -aspectWidth=16 \
      -aspectHeight=10 \
      -multiplierStep=80 \
      -virtualScreenHiDPI=on \
      -connected=on
  fi

  sleep 60
done
