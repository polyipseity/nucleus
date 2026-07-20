    # Disable Spotlight so Cmd+Space can be reused by alternate launchers such as
    # Raycast.  Each layer independently covers a vector:
    #   1) disable hotkeys 61/64/65 as the console user,
    #   2) force immediate hotkey reload with activateSettings -u,
    #   3) disable indexing with mdutil,
    #   4) clear stale /.Spotlight-V100 cache.
    #
    # This must stay in root system activation (not user activation) because
    # mdutil/launchctl service control are privileged operations.

    echo "spotlight: disabling..."

    if _nucleus_resolve_console_user; then
      for hotkey in 61 64 65; do
        if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
          /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$hotkey" \
          "<dict><key>enabled</key><false/></dict>"; then
          echo "spotlight: failed to disable hotkey $hotkey." >&2
        fi
      done

      if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
        /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
        echo "spotlight: hotkey changes applied; log out/in once to fully activate." >&2
      fi
    else
      echo "spotlight: skipped hotkey disable (no active non-root GUI session)." >&2
    fi

    if ! /usr/bin/mdutil -i off /; then
      echo "spotlight: failed to disable indexing." >&2
    fi

    if [ -d "/.Spotlight-V100" ]; then
      if ! /bin/rm -rf "/.Spotlight-V100"; then
        echo "spotlight: failed to remove /.Spotlight-V100 cache directory." >&2
      fi
    fi

    echo "spotlight: done."
