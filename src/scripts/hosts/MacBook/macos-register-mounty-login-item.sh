#!/usr/bin/env bash
# Ensure Mounty (NTFS auto-mounter) starts at login using the native macOS
# Login Items mechanism.  Mounty has no built-in launch-at-login preference;
# this keeps the declarative converge path consistent with other apps.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../lib/macos-console-user-lib.sh
. "$SCRIPT_DIR/../../lib/macos-console-user-lib.sh"

if _nucleus_resolve_console_user; then
      if [ -d "/Applications/Mounty.app" ]; then
        if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
          /usr/bin/osascript \
            -e 'tell application "System Events"' \
            -e 'if not (exists login item "Mounty") then' \
            -e 'make login item at end with properties {name:"Mounty", path:"/Applications/Mounty.app", hidden:false}' \
            -e 'end if' \
            -e 'end tell'; then
          echo "mounty: failed to ensure native Login Item startup for user '$_nucleus_console_user'." >&2
        fi
      fi
    fi
