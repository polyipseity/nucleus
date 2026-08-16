#!/usr/bin/env bash
# Hide LuLu's menu bar status icon by setting the daemon-side `noIconMode`
# preference (const PREF_NO_ICON_MODE; objective-see/LuLu@7d2669ed
# LuLu/Shared/consts.h) in /Library/Objective-See/LuLu/preferences.plist.
# When set, LuLu skips creating its status bar item (LuLu/App/AppDelegate.m
# completeInitialization:) — cosmetic only; alerts and firewall behavior are
# unchanged.
#
# WHY: the preference lives in the daemon install dir, and LuLu's daemon
# reads preferences.plist only at startup, then caches it in memory
# (LuLu/Shared/Preferences.m) and serves the cached copy to the app via XPC.
# A plain plist write therefore needs a daemon restart to take effect, and
# without it the daemon would clobber the write with its stale in-memory
# copy.  LuLu >= v3 has no LaunchDaemon (the v2 com.objective-see.lulu.plist
# no longer exists; /Library/LaunchDaemons/ and `launchctl list` show no LuLu
# label), so there is no launchd label to kickstart — the daemon runs as the
# network system extension process com.objective-see.lulu.extension (see
# `systemextensionsctl list` and LuLu/Extension/Extension.m
# isExtensionRunning, which detects it via findProcesses(EXT_BUNDLE_ID)).
# Terminating that process restarts the daemon; it re-reads the plist on next
# start.
#
# Takes no arguments; reads no environment variables.  Runs as root during
# system activation.  Exits non-zero if the preference write or the daemon
# termination fails; a daemon that is not running is fine — the preference
# applies at next daemon start.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

say -l lulu "hiding menu bar status icon..."

# Write the preference into the daemon-side plist.  `defaults` on an absolute
# .plist path merges just this key into the existing dictionary, leaving
# every other preference (rules, profiles, disabled state, ...) intact.
if ! /usr/bin/defaults write /Library/Objective-See/LuLu/preferences.plist noIconMode -bool YES; then
  error -l lulu "failed to write noIconMode preference to /Library/Objective-See/LuLu/preferences.plist."
  exit 1
fi

# Restart the daemon so the write takes effect: the system extension process
# is the daemon, and terminating it makes the system relaunch it, which
# re-reads the plist.
if /usr/bin/pgrep -x com.objective-see.lulu.extension >/dev/null; then
  if ! /bin/pkill -x com.objective-see.lulu.extension; then
    error -l lulu "failed to terminate daemon (com.objective-see.lulu.extension)."
    exit 1
  fi
  say -l lulu "daemon terminated; it re-reads preferences on next start."
else
  say -l lulu "daemon not running; preference applies at next daemon start."
fi

nuc_done -l lulu
