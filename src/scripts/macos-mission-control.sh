    # Forces Mission Control to span desktops across displays for the currently
    # logged-in console user.  Applying this from system activation ensures the
    # preference is re-asserted after migrations and major macOS updates that
    # sometimes reset com.apple.spaces user defaults.
    #
    # Algorithm:
    #   1. Resolve the active console UID from /dev/console.
    #   2. Skip when no non-root GUI session is present (e.g. headless rebuild).
    #   3. Use launchctl asuser to write the per-user defaults domain as that user.
    # undoc-supp: /dev/console may not exist (headless/SSH session); empty output is handled by the [ -z "$console_uid" ] guard below.
    console_uid="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)"

    if [ -z "$console_uid" ] || [ "$console_uid" -eq 0 ]; then
      echo "power: no active non-root console user; skipping spans-displays write." >&2
    else
      if ! /bin/launchctl asuser "$console_uid" /usr/bin/defaults write com.apple.spaces spans-displays -bool true; then
        echo "power: failed to enable Mission Control spans-displays for console uid $console_uid." >&2
      fi
    fi
