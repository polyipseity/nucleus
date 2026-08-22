#!/usr/bin/env bash
# Configure and activate Night Shift via the nightlight CLI tool.
# No-op if nightlight is not installed.
#
# Schedule: 18:00 -> 06:00, colour temperature 50 % (~4000 K).
# Source: https://github.com/smudge/nightlight
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

if [ -x "/opt/homebrew/bin/nightlight" ]; then
  NL_BIN="/opt/homebrew/bin/nightlight"

  if ! "$NL_BIN" schedule start; then
    die "failed to configure Nightlight schedule."
  fi

  # Read current temperature; skip setting if already at target value.
  # When the console user has a GUI session, run via launchctl asuser so
  # the CoreBrightness XPC service (needs WindowServer) is reachable.
  current_temp=$("$NL_BIN" temp 2>/dev/null || true) # check-suppress:suppression_doc: nightlight temp can fail in headless activation (no GUI XPC); idempotency path must not abort
  if [ "$current_temp" != "50" ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" temp 50; then
        die "failed to set Nightlight temperature."
      fi
    else
      if ! "$NL_BIN" temp 50; then
        die "failed to set Nightlight temperature."
      fi
    fi
  fi

  current_hour=$(date +%H)
  if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" on; then
        die "failed to enable Nightlight."
      fi
    else
      if ! "$NL_BIN" on; then
        die "failed to enable Nightlight."
      fi
    fi
  else
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" off; then
        die "failed to disable Nightlight."
      fi
    else
      if ! "$NL_BIN" off; then
        die "failed to disable Nightlight."
      fi
    fi
  fi
fi
