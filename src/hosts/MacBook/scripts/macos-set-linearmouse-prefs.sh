#!/usr/bin/env bash
# Keep LinearMouse update checks and auto-update disabled declaratively.
# These are Sparkle preferences in the app's defaults domain.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

if _nucleus_resolve_console_user; then
  if [ -d "/Applications/LinearMouse.app" ]; then
    if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write org.linearmouse.LinearMouse SUEnableAutomaticChecks -bool false; then
      die -l linearmouse "failed to disable automatic update checks for user '$_nucleus_console_user'."
    fi
    if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write org.linearmouse.LinearMouse SUAutomaticallyUpdate -bool false; then
      die -l linearmouse "failed to disable automatic updates for user '$_nucleus_console_user'."
    fi
  fi
fi
