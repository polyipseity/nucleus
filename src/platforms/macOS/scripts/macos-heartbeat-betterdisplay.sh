#!/usr/bin/env bash
# BetterDisplay virtual screen heartbeat: polls the HeadlessDisplay every 60
# seconds and reconnects it when BetterDisplay reports it disconnected. Restart
# tracking and loop detection come from svc_health and the watchdog.
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

# _bd_cli args...: run a BetterDisplay CLI command, soft-fail on error.
_bd_cli() {
  # check-suppress:suppression_doc: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
  svc_run_bounded 10 "$BD_BIN" "$@" || true
}

# Daemon loop: check every 60 s. _bd_connected_prev records the last observed
# state so a healthy tick is recorded once, not on every pass.
_bd_connected_prev=""
while true; do
  # No-op if BetterDisplay is not installed.
  if [ ! -f "$BD_BIN" ]; then
    sleep 60
    continue
  fi

  # Ensure BetterDisplay runs before issuing CLI commands.
  if ! /usr/bin/pgrep -xq "BetterDisplay" 2>/dev/null; then
    # No App Store receipt pre-flight: this host installs BetterDisplay from the
    # Homebrew cask (src/hosts/MacBook/homebrew.nix), which ships no
    # Contents/_MASReceipt, so the guard would block the relaunch permanently.

    # check-suppress:suppression_doc: BetterDisplay may not be installed yet; best-effort launch.
    /usr/bin/open -g -a "$BD_APP" || true
    svc_health_record_restart "betterdisplay-heartbeat" "relaunch"
    /bin/sleep 5
  fi

  # Connection check: any CLI error is soft-failed as unknown.
  connected_state="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"

  # Already connected: success is recorded only on the tick that connects, so it
  # marks the start of a healthy period.
  if [ "$connected_state" = "on" ]; then
    if [ "$_bd_connected_prev" != "on" ]; then
      svc_health_record_success "betterdisplay-heartbeat"
      _bd_connected_prev="on"
    fi
    sleep 60
    continue
  fi
  _bd_connected_prev=""

  # Disconnected or unknown. Try the set -connected=on toggle first: it is
  # free-tier-compatible for virtual screens, since Pro gating covers physical
  # display connection only. On failure, discard and recreate with the same
  # parameters as macos-headless-display so both paths agree on the spec.
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
