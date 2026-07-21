# Configure and activate Night Shift via the nightlight CLI tool.
# No-op if nightlight is not installed.
#
# Schedule: 18:00 -> 06:00, colour temperature 50 % (~4000 K).
# Source: https://github.com/smudge/nightlight
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

if [ -x "/opt/homebrew/bin/nightlight" ]; then
  if ! /opt/homebrew/bin/nightlight schedule start; then
    echo "macos: failed to configure Nightlight schedule." >&2
  fi

  if ! /opt/homebrew/bin/nightlight temp 50; then
    echo "macos: failed to set Nightlight temperature." >&2
  fi

  current_hour=$(date +%H)
  if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
    if ! /opt/homebrew/bin/nightlight on; then
      echo "macos: failed to enable Nightlight." >&2
    fi
  else
    if ! /opt/homebrew/bin/nightlight off; then
      echo "macos: failed to disable Nightlight." >&2
    fi
  fi
fi
