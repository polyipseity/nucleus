#!/usr/bin/env bash
# Provision UTM's global preferences for the console user: renderer backend,
# server settings, capture keys, and screenshot policy.
# WHY: UTM is sandboxed, so the prefs live in the app container
# (~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/), not
# ~/Library/Preferences; cfprefsd resolves the domain there when the write runs
# as the console user.  NoSaveScreenshot = true (plus the vm.sh provisioning
# purge) keeps VM bundles free of stale screenshots.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

# Write one preference into the sandboxed com.utmapp.UTM domain as the console
# user.  Best-effort: failures are reported to stderr, never fatal.
utm_write_default() {
  local key="$1"
  local flag="$2"
  local value="$3"
  if [ -f "$utm_container_prefs" ]; then
    # Container already registered (UTM launched before): write through
    # cfprefsd so the domain resolves to the container.
    if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write com.utmapp.UTM "$key" "$flag" "$value"; then
      warn -l utm "failed to set preference '$key' for user '$_nucleus_console_user'."
    fi
  else
    # UTM never launched, so its sandbox container does not exist yet.
    # Create the prefs directory and write the container plist directly;
    # cfprefsd adopts it when UTM first launches.
    if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /bin/mkdir -p "$(dirname "$utm_container_prefs")"; then
      warn -l utm "failed to create container prefs directory for user '$_nucleus_console_user'."
    elif ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write "$utm_container_prefs" "$key" "$flag" "$value"; then
      warn -l utm "failed to set preference '$key' for user '$_nucleus_console_user'."
    fi
  fi
}

if _nucleus_resolve_console_user; then
  if [ -d "/Applications/UTM.app" ]; then
    utm_container_prefs="/Users/$_nucleus_console_user/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
    # KEY FLAG VALUE per line; quoted values are de-quoted so the empty
    # ServerPassword string survives the read split.
    while read -r key flag value; do
      value="${value#\"}"
      value="${value%\"}"
      utm_write_default "$key" "$flag" "$value"
    done <<'EOF'
KeepRunningAfterLastWindowClosed -bool false
HideDockIcon -bool false
ShowMenuIcon -bool false
PreventIdleSleep -bool false
NoQuitConfirmation -bool true
NoUsbPrompt -bool true
NoCursorCaptureAlert -bool true
NoScreenshot -bool false
NoSaveScreenshot -bool true
FullScreenAutoCapture -bool true
WindowFocusAutoCapture -bool false
OptionAsMetaKey -bool false
CtrlRightClick -bool false
InvertScroll -bool false
HandleInitialClick -bool false
AlternativeCaptureKey -bool false
IsCapsLockKey -bool false
IsNumLockForced -bool false
IsCtrlCmdSwapped -bool false
IsISOKeySwapped -bool false
IsRegenerateMACOnClone -bool true
UseFileLock -bool true
ServerAutostart -bool false
ServerAutoblock -bool true
ServerExternal -bool false
ServerPasswordRequired -bool false
QEMURendererBackend -int 0
QEMUVulkanDriver -int 0
QEMUDirectXDriver -int 0
QEMURendererFPSLimit -int 0
QEMUSoundBackend -int 0
ServerPort -int 0
ServerPassword -string ""
EOF
  fi
else
  say -l utm "no active non-root console user; skipping UTM preferences provisioning."
fi
