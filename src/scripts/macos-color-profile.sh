    # Clears the ColorSync device-profile cache so that newly connected monitors
    # re-trigger profile detection and pick up the correct ICC profile.
    # ColorSync is a macOS-only subsystem; NixOS uses colord for ICC profile
    # management (handled by GNOME) and Windows has its own Color Management
    # subsystem — neither requires an equivalent cache-clearing step here.
    # Guard with a file-existence check: on fresh installs or machines with no
    # custom color profile the plist never exists, and `defaults delete` on a
    # missing domain emits a noisy "Domain not found" error that is neither a
    # real failure nor actionable.  Using [ -f ] avoids that entirely — if the
    # file is present we delete it; if not, there is nothing to do.
    if [ -f /Library/Preferences/com.apple.ColorSync.DeviceCache.plist ]; then
      /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache
    fi
