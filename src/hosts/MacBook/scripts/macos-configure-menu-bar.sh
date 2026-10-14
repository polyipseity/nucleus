#!/usr/bin/env bash
# Hide default macOS menu bar items (Spotlight, Control Centre battery) and
# set status-item spacing to the minimum floor of 0.
#
# macOS 27 caveat: Apple rewrote the menu bar, so its own system icons (Wi-Fi,
# Control Centre, clock) ignore NSStatusItemSpacing and only third-party status
# items tighten. A full logout may be required for the spacing writes to take
# effect; killing ControlCentre is not always enough.
#
# WHY an activation script and not CustomUserPreferences: ByHost
# (-currentHost) domains cannot be written that way, and the per-user domains
# need console-user context.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

say -l menu-bar "hiding default menu bar items..."

if _nucleus_resolve_console_user; then
  # Spotlight ByHost variant; the global-domain write is in defaults.nix.
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults -currentHost write com.apple.Spotlight MenuItemHidden -bool true; then
    error -l menu-bar "failed to hide Spotlight menu bar icon."
    exit 1
  fi

  # Battery hidden everywhere (12); Stats is the allow-listed battery display.
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults -currentHost write com.apple.controlcenter Battery -int 12; then
    error -l menu-bar "failed to hide Control Centre battery item."
    exit 1
  fi

  # Battery status item, per-user domain.
  if ! /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/defaults write com.apple.controlcenter "NSStatusItem Visible Battery" -bool false; then
    error -l menu-bar "failed to hide Control Centre battery status item."
    exit 1
  fi

  # Spacing at the documented floor of 0; 4 is the manual fallback if icons
  # overlap after this takes effect. These values only tighten third-party
  # items on macOS 27 (see header).
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

  # Restart Control Centre so the writes apply immediately. killall exits 1 when
  # it is not running, and the defaults still apply at next launch. On macOS 27
  # this may not move the spacing at all; a full logout is the fallback (see
  # header).
  /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/killall ControlCenter 2>/dev/null || true # check-suppress:suppression_doc: Control Centre may not be running; killall exits 1, defaults persist and apply at next launch
else
  say -l menu-bar "skipped (no GUI session)."
fi

nuc_done -l menu-bar
