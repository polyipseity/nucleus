#!/usr/bin/env bash
# Keep UTM's global renderer backend pinned to ANGLE (OpenGL) for the console
# user.
# WHY: Android (LineageOS) guests on UTM require ANGLE (OpenGL) for the UI to
# appear after boot; ANGLE (Metal) hides the UI and the default software
# renderer is prone to a frozen display (UTM issue #378).  UTM is sandboxed, so
# the pref lives in the app container
# (~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/), not
# ~/Library/Preferences; cfprefsd resolves the domain there when the write runs
# as the console user.
# ref: https://wiki.lineageos.org/utms/utm-vm-on-apple-silicon-mac -- renderer backend must be ANGLE (OpenGL) for the Android UI to appear
# ref: https://github.com/utmapp/UTM/issues/378 -- Android VMs randomly freeze; renderer-dependent

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../lib/macos-console-user.sh
. "$SCRIPT_DIR/../../lib/macos-console-user.sh"

if _nucleus_resolve_console_user; then
  if [ -d "/Applications/UTM.app" ]; then
    utm_container_prefs="/Users/$_nucleus_console_user/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
    if [ -f "$utm_container_prefs" ]; then
      # Container already registered (UTM launched before): write through
      # cfprefsd so the domain resolves to the container.
      if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write com.utmapp.UTM QEMURendererBackend -int 1; then
        echo "utm: failed to set renderer backend to ANGLE (OpenGL) for user '$_nucleus_console_user'." >&2
      fi
    else
      # UTM never launched, so its sandbox container does not exist yet.
      # Create the prefs directory and write the container plist directly;
      # cfprefsd adopts it when UTM first launches.
      if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /bin/mkdir -p "$(dirname "$utm_container_prefs")"; then
        echo "utm: failed to create container prefs directory for user '$_nucleus_console_user'." >&2
      elif ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write "$utm_container_prefs" QEMURendererBackend -int 1; then
        echo "utm: failed to set renderer backend to ANGLE (OpenGL) for user '$_nucleus_console_user'." >&2
      fi
    fi
  fi
else
  echo "utm: no active non-root console user; skipping renderer backend provisioning." >&2
fi
