    # Remove Steam from macOS Login Items so it does not auto-launch when the
    # user logs in.  Steam registers itself as a login item during installation;
    # this block ensures the declarative config overrides that choice.
    #
    # Cross-platform parity:
    #   macOS   — this block (System Events login item removal)
    #   NixOS   — xdg autostart exclusion in desktop.nix
    #   Windows — Disable-SteamAutoStartup module + apply.ps1
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      if [ -d "/Applications/Steam.app" ]; then
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
    fi
