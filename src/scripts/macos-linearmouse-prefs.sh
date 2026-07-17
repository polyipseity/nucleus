    # Keep LinearMouse update checks and auto-update disabled declaratively.
    # These are Sparkle preferences in the app's defaults domain.
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      if [ -d "/Applications/LinearMouse.app" ]; then
        # undoc-supp: see MiddleClick pattern — console uid probe may fail.
        console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
        if [ -n "$console_uid" ]; then
          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/defaults write com.lujjjh.LinearMouse SUEnableAutomaticChecks -bool false; then
            echo "linearmouse: failed to disable automatic update checks for user '$console_user'." >&2
          fi
          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/defaults write com.lujjjh.LinearMouse SUAutomaticallyUpdate -bool false; then
            echo "linearmouse: failed to disable automatic updates for user '$console_user'." >&2
          fi
        fi
      fi
    fi
