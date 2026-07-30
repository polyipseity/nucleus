#!/usr/bin/env bash
# Configure external display resolutions to match the built-in MacBook display.
# Uses displayplacer to match all external monitors to the built-in screen's
# current mode so remote-desktop clients see a consistent resolution.
#
# Algorithm:
#   1. Identify the built-in screen's persistent ID and its current mode.
#   2. If the built-in is on mode 4 (high-DPI Retina mode), apply it first
#      to ensure the reference resolution is set correctly.
#   3. Re-read the current mode string to obtain target width/height and
#      the scaling flag.
#   4. For each external display, find the mode whose width >= target width
#      and height <= target height (so it fits within the same logical area)
#      with the smallest height (closest match without overshooting).
#
# No-op if displayplacer is not installed.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-console-user.sh"

DP_BIN="/opt/homebrew/bin/displayplacer"

if [ -x "$DP_BIN" ]; then
  FULL_LIST=$("$DP_BIN" list)

  # Locate the persistent ID of the built-in MacBook screen.
  PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/awk '
    /^Persistent screen id:/ { last_id=$4 }
    /Type: MacBook built in screen/ { print last_id; exit }
  ')

  # Fall back to the first listed display if the built-in label is absent.
  if [ -z "$PRIMARY_ID" ]; then
    PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/head -n 1 | /usr/bin/awk '{print $4}')
  fi

  # Read the mode 4 string for the primary display (native HiDPI mode).
  MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
    $0 ~ id { found=1 }
    found && /^  mode 4:/ {
      sub(/^[ ]*mode 4: /, "");
      sub(/[ ]*<-- current mode/, "");
      print $0;
      exit;
    }
  ')

  # If mode 4 is not available, read whichever mode is currently active.
  if [ -z "$MODE4_STR" ]; then
    MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
      $0 ~ id { found=1 }
      found && /<-- current mode/ {
        sub(/^[ ]*mode [0-9]+: /, "");
        sub(/[ ]*<-- current mode/, "");
        print $0;
        exit;
      }
    ')
  fi

  # Check if mode 4 is already the current mode on the primary display.
  # displayplacer apply needs WindowServer context (GUI session); skip when
  # already at the target mode to avoid spurious errors during headless
  # activation.
  MODE4_CURRENT=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
    $0 ~ id { found=1 }
    found && /mode 4:.*<-- current mode/ { print "yes"; exit }
  ')

  # Apply the target mode on the primary display and refresh the list.
  # Run via launchctl asuser when a GUI session is available (displayplacer
  # needs CoreGraphics/WindowServer context); fall back to direct invocation
  # otherwise so the command still works under test or headless apply.
  if [ -n "$MODE4_STR" ] && [ "$MODE4_CURRENT" != "yes" ]; then
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR"; then
        echo "macos: failed to apply primary display mode with displayplacer." >&2
      fi
    else
      if ! "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR"; then
        echo "macos: failed to apply primary display mode with displayplacer." >&2
      fi
    fi
    /bin/sleep 1
    FULL_LIST=$("$DP_BIN" list)
  fi

  # Read the mode that is now active on the primary display to use as
  # the reference resolution for external monitors.
  TARGET_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
    $0 ~ id { found=1 }
    found && /<-- current mode/ {
      sub(/^[ ]*mode [0-9]+: /, "");
      sub(/[ ]*<-- current mode/, "");
      print $0;
      exit;
    }
  ')

  # Extract width, height, and scaling flag from the target mode string.
  T_W=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:([0-9]+)x.*/\1/')
  T_H=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:[0-9]+x([0-9]+).*/\1/')
  T_SCALING=""
  if echo "$TARGET_STR" | /usr/bin/grep -q "scaling:on"; then
    T_SCALING="scaling:on"
  fi

  # For each external display, select the best matching mode and apply it.
  for ID in $(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/awk '{print $4}'); do
    if [ "$ID" = "$PRIMARY_ID" ]; then
      continue
    fi

    MODES=$(echo "$FULL_LIST" | /usr/bin/sed -n "/^Persistent screen id: $ID/,/^Persistent screen id:/p" | /usr/bin/grep "^  mode " | /usr/bin/sed 's/^  mode [0-9]*: //')
    # When the primary uses HiDPI scaling, restrict candidates to HiDPI modes.
    if [ -n "$T_SCALING" ]; then
      MODES=$(echo "$MODES" | /usr/bin/grep "scaling:on")
    fi

    # Pick the mode with the smallest height that is still >= target width
    # and <= target height (fits the same logical area, highest PPI wins).
    BEST_MODE=$(echo "$MODES" | /usr/bin/awk -v tw="$T_W" -v th="$T_H" '{ w=substr($0,index($0,"res:")+4); gsub(/[^0-9].*/,"",w); h=substr($0,index($0,"x")+1); gsub(/[^0-9].*/,"",h); if (w+0>=tw+0 && h+0<=th+0 && h+0>0) print w+0, h+0, $0 }' | /usr/bin/sort -n | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f3- | /usr/bin/sed 's/ <-- current mode$//')

    if [ -n "$BEST_MODE" ]; then
      if _nucleus_resolve_console_user; then
        if ! /bin/launchctl asuser "$_nucleus_console_uid" "$DP_BIN" "id:$ID $BEST_MODE"; then
          echo "macos: failed to apply mode '$BEST_MODE' to display id $ID." >&2
        fi
      else
        if ! "$DP_BIN" "id:$ID $BEST_MODE"; then
          echo "macos: failed to apply mode '$BEST_MODE' to display id $ID." >&2
        fi
      fi
    fi
  done
fi
