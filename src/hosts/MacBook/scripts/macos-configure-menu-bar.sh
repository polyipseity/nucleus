#!/usr/bin/env bash
# Hide default macOS menu bar items (Spotlight, Control Centre battery) and
# clamp status-item spacing to the minimum floor.  Activation script rather
# than system.defaults.CustomUserPreferences: ByHost domains (-currentHost)
# cannot be written that way, and per-user domains need console-user context.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

say -l menu-bar "hiding default menu bar items..."

if _nucleus_resolve_console_user; then
  # 1) Spotlight menu bar icon (ByHost variant; the global-domain write is
  #    already in defaults.nix).
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults -currentHost write com.apple.Spotlight MenuItemHidden -bool true; then
    error -l menu-bar "failed to hide Spotlight menu bar icon."
    exit 1
  fi

  # 2) Control Centre battery item hidden everywhere (12 = hidden everywhere;
  #    Stats is the allow-listed battery display).
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults -currentHost write com.apple.controlcenter Battery -int 12; then
    error -l menu-bar "failed to hide Control Centre battery item."
    exit 1
  fi

  # 3) Control Centre battery status item (per-user domain).
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults write com.apple.controlcenter "NSStatusItem Visible Battery" -bool false; then
    error -l menu-bar "failed to hide Control Centre battery status item."
    exit 1
  fi

  # 4) Status-item spacing at the minimum floor.  0 is the documented floor;
  #    4 is the manual fallback if icons overlap after this takes effect.
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults -currentHost write -globalDomain NSStatusItemSpacing -int 0; then
    error -l menu-bar "failed to set NSStatusItemSpacing."
    exit 1
  fi
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 0; then
    error -l menu-bar "failed to set NSStatusItemSelectionPadding."
    exit 1
  fi

  # 5) Restart Control Centre so the writes apply immediately.  killall exits
  #    1 with "No matching processes were found" when Control Centre is not
  #    running; that is fine — the defaults persist and apply at next launch.
  /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/killall ControlCenter 2>/dev/null || true # check-suppress:suppression_doc: Control Centre may not be running; killall exits 1, defaults persist and apply at next launch
else
  say -l menu-bar "skipped (no GUI session)."
fi

say -l menu-bar "done."
