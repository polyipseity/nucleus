#!/usr/bin/env bash
# Disable Spotlight so Cmd+Space can be reused by alternate launchers such as
# Raycast.  Each layer independently covers a vector:
#   1) disable hotkeys 61/64/65 as the console user,
#   2) force immediate hotkey reload with activateSettings -u,
#   3) disable indexing with mdutil,
#   4) clear stale /.Spotlight-V100 cache.
#
# This must stay in root system activation (not user activation) because
# mdutil/launchctl service control are privileged operations.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

say -l spotlight "disabling..."

if _nucleus_resolve_console_user; then
  for hotkey in 61 64 65; do
    if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
      /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$hotkey" \
      "<dict><key>enabled</key><false/></dict>"; then
      die -l spotlight "failed to disable hotkey $hotkey."
    fi
  done

  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
    die -l spotlight "hotkey changes applied; log out/in once to fully activate."
  fi
else
  say -l spotlight "skipped hotkey disable (no active non-root GUI session)."
fi

if ! /usr/bin/mdutil -i off /; then
  die -l spotlight "failed to disable indexing."
fi

if [ -d "/.Spotlight-V100" ]; then
  if ! /bin/rm -rf "/.Spotlight-V100"; then
    # check-suppress:suppression_doc: cache dir may not exist; removal is best-effort cleanup, not a config write
    warn -l spotlight "failed to remove /.Spotlight-V100 cache directory."
  fi
fi

nuc_done -l spotlight
