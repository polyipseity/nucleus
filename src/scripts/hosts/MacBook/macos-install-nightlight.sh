#!/usr/bin/env bash
# Configure and activate Night Shift via the nightlight CLI tool.
# No-op if nightlight is not installed.
#
# Schedule: 18:00 -> 06:00, colour temperature 50 % (~4000 K).
# Source: https://github.com/smudge/nightlight
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-console-user-lib.sh"

if [ -x "/opt/homebrew/bin/nightlight" ]; then
  NL_BIN="/opt/homebrew/bin/nightlight"

  if ! "$NL_BIN" schedule start; then
    echo "macos: failed to configure Nightlight schedule." >&2
  fi

  # Read current temperature; skip setting if already at target value.
  # When the console user has a GUI session, run via launchctl asuser so
  # the CoreBrightness XPC service (needs WindowServer) is reachable.
  current_temp=$("$NL_BIN" temp 2>/dev/null || true) # undoc-supp: nightlight temp can fail in headless activation (no GUI XPC); idempotency path must not abort
  if [ "$current_temp" != "50" ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" temp 50; then
        echo "macos: failed to set Nightlight temperature." >&2
      fi
    else
      if ! "$NL_BIN" temp 50; then
        echo "macos: failed to set Nightlight temperature." >&2
      fi
    fi
  fi

  current_hour=$(date +%H)
  if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" on; then
        echo "macos: failed to enable Nightlight." >&2
      fi
    else
      if ! "$NL_BIN" on; then
        echo "macos: failed to enable Nightlight." >&2
      fi
    fi
  else
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" off; then
        echo "macos: failed to disable Nightlight." >&2
      fi
    else
      if ! "$NL_BIN" off; then
        echo "macos: failed to disable Nightlight." >&2
      fi
    fi
  fi
fi
