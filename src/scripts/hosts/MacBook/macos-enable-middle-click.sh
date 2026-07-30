#!/usr/bin/env bash
# Set MiddleClick gesture recognition to 4 fingers and ensure it starts at
# login using the native macOS Login Items mechanism (not LaunchAgent).
# WHY 4 fingers: TFD uses 3 fingers; using 4 for middle-click prevents both
# the TFD conflict and the phantom left-click issue described at
# https://github.com/artginzburg/MiddleClick/blob/main/docs/three-finger-drag.md
# WHY native login item: MiddleClick upstream manages startup through macOS
# Login Items APIs (ServiceManagement), so declarative convergence should
# target that same system surface instead of maintaining a parallel
# LaunchAgent path.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../lib/macos-console-user.sh
. "$SCRIPT_DIR/../../lib/macos-console-user.sh"

if _nucleus_resolve_console_user; then
      if [ -d "/Applications/MiddleClick.app" ]; then
        if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
          /usr/bin/defaults write art.ginzburg.MiddleClick fingers -int 4; then
          echo "middleclick: failed to set fingers=4 for user '$_nucleus_console_user'." >&2
        fi

        if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
          /usr/bin/osascript \
            -e 'tell application "System Events"' \
            -e 'if not (exists login item "MiddleClick") then' \
            -e 'make login item at end with properties {name:"MiddleClick", path:"/Applications/MiddleClick.app", hidden:true}' \
            -e 'end if' \
            -e 'end tell'; then
          echo "middleclick: failed to ensure native Login Item startup for user '$_nucleus_console_user'; enable 'Launch at login' from MiddleClick menu as fallback." >&2
        fi
      fi
    fi
