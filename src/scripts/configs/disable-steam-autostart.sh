#!/usr/bin/env bash
# Suppress Steam autostart at user login.
# Cross-platform parity:
#   macOS   — login item removal via osascript when Steam.app is present
#   NixOS   — remove ~/.config/autostart/steam.desktop
#   Windows — Disable-SteamAutoStartup module + apply.ps1
set -euo pipefail

case "$(uname)" in
  Darwin)
    # Remove Steam from macOS Login Items via System Events.
    # console_user is expected from the activation context.
    if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ -d "/Applications/Steam.app" ]; then
      # undoc-supp: console uid probe may fail if console session ended; [ -n "$console_uid" ] guard handles empty output.
      console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
      if [ -n "$console_uid" ]; then
        if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
          /usr/bin/osascript \
            -e 'tell application "System Events"' \
            -e 'if exists login item "Steam" then' \
            -e 'delete login item "Steam"' \
            -e 'end if' \
            -e 'end tell' 2>/dev/null; then
          echo "steam: failed to remove login item." >&2
        fi
      fi
    fi
    ;;
  Linux)
    # Remove Steam autostart .desktop file if present.
    # undoc-supp: steam autostart entry may not exist on first install; best-effort cleanup that should not abort activation.
    find /home -maxdepth 3 -path '*/autostart/steam.desktop' -delete 2>/dev/null || true
    ;;
esac
