#!/usr/bin/env bash
# Keep UTM's global renderer backend pinned to Apple Core OpenGL (CGL) for the
# console user.
# WHY: The Android (LineageOS) guest UI only appears with a GL renderer
# backend; ANGLE (Metal) hides the UI after boot (LineageOS wiki) and the
# ANGLE (OpenGL) path was the historic freeze-prone default (UTM issue #378).
# UTM 5.x added a native CGL (Apple Core OpenGL) backend (QEMURendererBackend
# = 3, kQEMURendererBackendCGL), the maintained GL path for Android on UTM.
# The recurring "display freezes randomly" bug is NOT renderer-dependent: it
# is a client-side SPICE display-channel stall in UTM's SPICE client
# (CocoaSpice#5 scanout-texture race, read() deadlock; UTM #2221), observed
# locally as the SPICE Main Loop blocked in playback_stop ->
# gst_element_set_state, freezing the single glib main loop that dispatches
# all SPICE channels (display + QMP-over-spiceport; utmctl suspend fails with
# "Timed out waiting for RPC").  UTM 5.0.4 (2026-08-01) ships targeted SPICE
# renderer + memory-leak fixes; zero-cost mitigation: keep the VM window
# visible.  Full findings in .agents/instructions/utm-android-freeze.instructions.md.
# UTM is sandboxed, so the pref lives in the app container
# (~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/), not
# ~/Library/Preferences; cfprefsd resolves the domain there when the write runs
# as the console user.
# ref: https://github.com/utmapp/UTM/blob/v5.0.3/Services/UTMQemuSystemBackends.h -- kQEMURendererBackendCGL = 3
# ref: https://wiki.lineageos.org/utms/utm-vm-on-apple-silicon-mac -- Android UI renderer guidance
# ref: https://github.com/utmapp/UTM/issues/2221 -- "Display freezes randomly"; renderer-orthogonal SPICE stall
# ref: https://github.com/utmapp/CocoaSpice/issues/5 -- scanout-texture race, read() deadlock; mitigated, not fixed
# ref: https://github.com/utmapp/UTM/issues/5886 -- guest kernel trace: virtio-gpu queue fills when client stalls

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../lib/macos-console-user.sh
. "$SCRIPT_DIR/../../lib/macos-console-user.sh"

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
