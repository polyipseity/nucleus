    # Ensure Mounty (NTFS auto-mounter) starts at login using the native macOS
    # Login Items mechanism.  Mounty has no built-in launch-at-login preference;
    # this keeps the declarative converge path consistent with other apps.
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      if [ -d "/Applications/Mounty.app" ]; then
        # undoc-supp: see MiddleClick pattern — console uid probe may fail.
        console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
        if [ -n "$console_uid" ]; then
          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
            /usr/bin/osascript \
              -e 'tell application "System Events"' \
              -e 'if not (exists login item "Mounty") then' \
              -e 'make login item at end with properties {name:"Mounty", path:"/Applications/Mounty.app", hidden:false}' \
              -e 'end if' \
              -e 'end tell'; then
            echo "mounty: failed to ensure native Login Item startup for user '$console_user'." >&2
          fi
        fi
      fi
    fi
