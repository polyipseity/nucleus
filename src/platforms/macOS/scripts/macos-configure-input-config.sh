#!/usr/bin/env bash
# Configure input method settings and refresh TISwitcher.
# Replaces the input-config inline activation block.
#
# Usage: configure-input-config
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../../scripts/lib/macos-launch-services.sh"

# Source: symbolic hotkey values are persisted in
# com.apple.symbolichotkeys/AppleSymbolicHotKeys via defaults(1).
if ! /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>"; then
  echo "configure-input-config: failed to update symbolic hotkey 176." >&2
fi

if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
  echo "configure-input-config: activateSettings -u failed; input settings may apply on next login." >&2
fi

refresh_tiswitcher
