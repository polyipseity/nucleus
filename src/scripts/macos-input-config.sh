# Configure input method settings and disable conflicting hotkeys.
set -eu

# Source: symbolic hotkey values are persisted in
# com.apple.symbolichotkeys/AppleSymbolicHotKeys via defaults(1).
# https://www.manpagez.com/man/1/defaults/
if ! /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>"; then
  echo "macos: failed to update symbolic hotkey 176." >&2
fi

if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
  echo "macos: activateSettings -u failed; input settings may apply on next login." >&2
fi
