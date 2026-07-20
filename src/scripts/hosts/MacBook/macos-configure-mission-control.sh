    # Forces Mission Control to span desktops across displays for the currently
    # logged-in console user.  Applying this from system activation ensures the
    # preference is re-asserted after migrations and major macOS updates that
    # sometimes reset com.apple.spaces user defaults.
    if _nucleus_resolve_console_user; then
      if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/defaults write com.apple.spaces spans-displays -bool true; then
        echo "power: failed to enable Mission Control spans-displays for console uid $_nucleus_console_uid." >&2
      fi
    else
      echo "power: no active non-root console user; skipping spans-displays write." >&2
    fi
