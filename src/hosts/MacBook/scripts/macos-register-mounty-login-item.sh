#!/usr/bin/env bash
# Enable Mounty (NTFS auto-mounter) launch-at-login via Mounty's native API.
# Mounty's "Start at Login" checkbox calls SMLoginItemSetEnabled on the
# LSBackgroundOnly helper bundle com.cu4uc.MountyHelper, which launches the
# main app at login; we invoke that same native API declaratively via JXA
# (osascript -l JavaScript) instead of registering the app ourselves.
# WHY: SMLoginItemSetEnabled is deprecated (macOS 13+) but still functional and
#   is exactly what Mounty's own checkbox calls — no SMAppService equivalent
#   exists for this third-party helper.  JXA is used because osascript ships
#   with macOS, so there is no Command Line Tools dependency.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

if _nucleus_resolve_console_user; then
  if [ -d "/Applications/Mounty.app" ]; then
    # shellcheck disable=SC2016 # reason: JXA expression passed to osascript; $ is JavaScript, not shell expansion
    if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
      /usr/bin/osascript -l JavaScript \
      -e 'ObjC.import("ServiceManagement"); if (!$.SMLoginItemSetEnabled($("com.cu4uc.MountyHelper"), true)) throw new Error("SMLoginItemSetEnabled failed");'; then
      echo "mounty: failed to ensure native Login Item startup for user '$_nucleus_console_user'." >&2
    fi
  fi
fi
