#!/usr/bin/env bash
# Keep UTM's global renderer backend pinned to Apple Core OpenGL (CGL) for the
# console user.
# WHY: The Android (LineageOS) guest UI only appears with a GL renderer
# backend; UTM 5.x CGL (QEMURendererBackend = 3) is the maintained GL path.
# ref: vm-management.instructions.md -- Android UTM freeze and renderer policy
# UTM is sandboxed, so the pref lives in the app container
# (~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/), not
# ~/Library/Preferences; cfprefsd resolves the domain there when the write runs
# as the console user.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

if _nucleus_resolve_console_user; then
  if [ -d "/Applications/UTM.app" ]; then
    utm_container_prefs="/Users/$_nucleus_console_user/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
    if [ -f "$utm_container_prefs" ]; then
      # Container already registered (UTM launched before): write through
      # cfprefsd so the domain resolves to the container.
      if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write com.utmapp.UTM QEMURendererBackend -int 3; then
        echo "utm: failed to set renderer backend to Apple Core OpenGL (CGL) for user '$_nucleus_console_user'." >&2
      fi
    else
      # UTM never launched, so its sandbox container does not exist yet.
      # Create the prefs directory and write the container plist directly;
      # cfprefsd adopts it when UTM first launches.
      if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /bin/mkdir -p "$(dirname "$utm_container_prefs")"; then
        echo "utm: failed to create container prefs directory for user '$_nucleus_console_user'." >&2
      elif ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write "$utm_container_prefs" QEMURendererBackend -int 3; then
        echo "utm: failed to set renderer backend to Apple Core OpenGL (CGL) for user '$_nucleus_console_user'." >&2
      fi
    fi
  fi
else
  echo "utm: no active non-root console user; skipping renderer backend provisioning." >&2
fi
