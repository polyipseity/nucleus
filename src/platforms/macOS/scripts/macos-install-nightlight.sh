#!/usr/bin/env bash
# Configure and activate Night Shift via the nightlight CLI tool.
# No-op if nightlight is not installed.
#
# Schedule: 18:00 -> 06:00, colour temperature 50 % (~4000 K).
# Source: https://github.com/smudge/nightlight
#
# WHY: Night Shift operations (temperature, schedule, on/off) need a live GUI
# session with CoreBrightness XPC available. During headless activation (no
# display, lid closed, or remote SSH) they fail even though the configuration is
# correct, so they warn and the setting takes effect at next GUI login.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

if [ -x "/opt/homebrew/bin/nightlight" ]; then
  NL_BIN="/opt/homebrew/bin/nightlight"

  if ! "$NL_BIN" schedule start; then
    warn "failed to configure Nightlight schedule."
  fi

  # Skip setting when the temperature already sits at the target.
  # WHY: launchctl asuser reaches the CoreBrightness XPC service, which needs
  # WindowServer and therefore a real GUI session.
  current_temp=$("$NL_BIN" temp 2>/dev/null || true) # check-suppress:suppression_doc: nightlight temp can fail in headless activation (no GUI XPC); idempotency path must not abort
  if [ "$current_temp" != "50" ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" temp 50; then
        warn "failed to set Nightlight temperature."
      fi
    else
      if ! "$NL_BIN" temp 50; then
        warn "failed to set Nightlight temperature."
      fi
    fi
  fi

  current_hour=$(date +%H)
  if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" on; then
        warn "failed to enable Nightlight."
      fi
    else
      if ! "$NL_BIN" on; then
        warn "failed to enable Nightlight."
      fi
    fi
  else
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$NL_BIN" off; then
        warn "failed to disable Nightlight."
      fi
    else
      if ! "$NL_BIN" off; then
        warn "failed to disable Nightlight."
      fi
    fi
  fi
fi
