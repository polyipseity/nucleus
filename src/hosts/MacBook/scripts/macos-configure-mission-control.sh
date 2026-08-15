#!/usr/bin/env bash
# Forces Mission Control to span desktops across displays for the currently
# logged-in console user.  Applying this from system activation ensures the
# preference is re-asserted after migrations and major macOS updates that
# sometimes reset com.apple.spaces user defaults.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

if _nucleus_resolve_console_user; then
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/defaults write com.apple.spaces spans-displays -bool true; then
    warn -l power "failed to enable Mission Control spans-displays for console uid $_nucleus_console_uid."
  fi
else
  say -l power "no active non-root console user; skipping spans-displays write." >&2
fi
