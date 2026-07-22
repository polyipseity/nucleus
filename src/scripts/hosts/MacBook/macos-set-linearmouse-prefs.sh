#!/usr/bin/env bash
    # Keep LinearMouse update checks and auto-update disabled declaratively.
    # These are Sparkle preferences in the app's defaults domain.
    if _nucleus_resolve_console_user; then
      # shellcheck disable=SC2154 # reason: set by _nucleus_resolve_console_user from Nix-prepended macos-console-user-lib.sh
      if [ -d "/Applications/LinearMouse.app" ]; then
        if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write com.lujjjh.LinearMouse SUEnableAutomaticChecks -bool false; then
          echo "linearmouse: failed to disable automatic update checks for user '$_nucleus_console_user'." >&2
        fi
        if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/defaults write com.lujjjh.LinearMouse SUAutomaticallyUpdate -bool false; then
          echo "linearmouse: failed to disable automatic updates for user '$_nucleus_console_user'." >&2
        fi
      fi
    fi
