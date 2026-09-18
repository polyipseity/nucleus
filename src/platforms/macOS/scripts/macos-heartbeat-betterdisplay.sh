#!/usr/bin/env bash
# BetterDisplay virtual screen heartbeat.  Polls the HeadlessDisplay every 60
# seconds and reconnects it if BetterDisplay marks it as disconnected.
# Includes crash-loop detection: stops relaunching after ≥10 restarts/hour
# or ≥5 consecutive failures.
#
# Environment variables (with built-in defaults):
#   BD_BIN  — path to BetterDisplay executable
#   BD_APP  — path to BetterDisplay .app bundle
#   DISPLAY_NAME — virtual display name to monitor

set +e # heartbeat is fully soft-fail; never abort on individual check failure

# Source crash-loop detection library.
_BD_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/crash-loop.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/crash-loop.sh"

: "${BD_BIN:=/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}" \
  "${BD_APP:=/Applications/BetterDisplay.app}" \
  "${DISPLAY_NAME:=HeadlessDisplay}"

# _bd_run_bounded <seconds> <command> [args...] — Run a command with a hard
# timeout, returning its exit status (143 when the timeout fired).
#
# WHY: the BetterDisplay CLI blocks indefinitely when the app is unresponsive
# (observed: a single invocation never returned). launchd restarts a crashed
# agent, not a hung one, so without this bound one stuck call would silently end
# every later heartbeat for the rest of the login session.
_bd_run_bounded() {
  local _timeout="$1"
  shift

  "$@" &
  local _pid=$!
  local _waited=0
  # check-suppress:suppression_doc: kill -0 is the liveness probe itself; it reports failure on exactly the tick the child has exited, which is the intended loop exit.
  while kill -0 "$_pid" 2>/dev/null; do
    sleep 1
    _waited=$((_waited + 1))
    if [ "$_waited" -ge "$_timeout" ]; then
      # check-suppress:suppression_doc: the child is already gone in the common race below; a failed kill is not actionable.
      kill -9 "$_pid" 2>/dev/null
      # Reap the child; its status is intentionally discarded because this branch
      # reports the timeout (143) rather than the killed child's signal status.
      wait "$_pid"
      return 143
    fi
  done
  wait "$_pid"
}

# _bd_cli args... — Execute BetterDisplay CLI command, soft-fail on error.
_bd_cli() {
  # check-suppress:suppression_doc: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
  _bd_run_bounded 10 "$BD_BIN" "$@" || true
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
    # Crash-loop detection: stop relaunching if service is crash-looping.
    if crash_loop_is_looping "betterdisplay-heartbeat"; then
      warn "betterdisplay-heartbeat: crash-loop detected — skipping launch"
      sleep 60
      continue
    fi

    # No App Store receipt pre-flight here on purpose: this host installs
    # BetterDisplay from the Homebrew cask (src/hosts/MacBook/homebrew.nix),
    # which ships no Contents/_MASReceipt. A receipt guard would therefore block
    # the relaunch path permanently instead of guarding it.

    # check-suppress:suppression_doc: BetterDisplay may not be installed yet; best-effort launch.
    /usr/bin/open -g -a "$BD_APP" || true
    crash_loop_record "betterdisplay-heartbeat" "relaunch"
    /bin/sleep 5
  fi

  # Check connection state; soft-fail by treating any CLI error as unknown.
  connected_state="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"

  # No-op if already connected. Success is recorded only when the display has
  # just become connected: it marks the start of a healthy period, which is the
  # only instant crash-loop detection needs to know about.
  if [ "$connected_state" = "on" ]; then
    if [ "$_bd_connected_prev" != "on" ]; then
      crash_loop_success "betterdisplay-heartbeat"
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
  if ! _bd_run_bounded 10 "$BD_BIN" set -name="$DISPLAY_NAME" -connected=on; then
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
