    # Set MiddleClick gesture recognition to 4 fingers and ensure it starts at
    # login using the native macOS Login Items mechanism (not LaunchAgent).
    # WHY 4 fingers: TFD uses 3 fingers; using 4 for middle-click prevents both
    # the TFD conflict and the phantom left-click issue described at
    # https://github.com/artginzburg/MiddleClick/blob/main/docs/three-finger-drag.md
    # WHY native login item: MiddleClick upstream manages startup through macOS
    # Login Items APIs (ServiceManagement), so declarative convergence should
    # target that same system surface instead of maintaining a parallel
    # LaunchAgent path.
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      if [ -d "/Applications/MiddleClick.app" ]; then
        # undoc-supp: console_uid probe may fail if console session ended; empty result is handled by the [ -n "$console_uid" ] guard.
        console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
        if [ -n "$console_uid" ]; then
          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
            /usr/bin/defaults write art.ginzburg.MiddleClick fingers -int 4; then
            echo "middleclick: failed to set fingers=4 for user '$console_user'." >&2
          fi

          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
            /usr/bin/osascript \
              -e 'tell application "System Events"' \
              -e 'if not (exists login item "MiddleClick") then' \
              -e 'make login item at end with properties {name:"MiddleClick", path:"/Applications/MiddleClick.app", hidden:true}' \
              -e 'end if' \
              -e 'end tell'; then
            echo "middleclick: failed to ensure native Login Item startup for user '$console_user'; enable 'Launch at login' from MiddleClick menu as fallback." >&2
          fi
        fi
      fi
    fi
