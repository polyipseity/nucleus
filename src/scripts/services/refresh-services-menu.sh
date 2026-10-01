#!/usr/bin/env bash
# Refresh LaunchServices and pasteboard daemon caches so new Automator
# workflows and App bundles appear in the Services menu immediately, then force
# pbs to rescan so pruned bundles stop being served from its caches.
#
# Args: PBS_BIN LAUNCHCTL_BIN SUDO_BIN

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/macos-launch-services.sh
. "$SCRIPT_DIR/../lib/macos-launch-services.sh"
# shellcheck source=../lib/macos-console-user.sh
. "$SCRIPT_DIR/../lib/macos-console-user.sh"

_rsm_pbs_bin="$1"
_rsm_launchctl_bin="$2"
_rsm_sudo_bin="$3"

# pbs must re-read pbs.plist first: it holds the enabled state the deploy steps
# just wrote, and the rescan below publishes it.
refresh_services_menu

# WHY: the rescan needs the console user's session. pbs keeps per-user caches,
# so a root-scoped apply would otherwise refresh root's Services instead.
if _nucleus_resolve_console_user; then
  if ! rescan_pbs_services "$_rsm_pbs_bin" "$_rsm_launchctl_bin" "$_rsm_sudo_bin" \
    "$_nucleus_console_uid" "$_nucleus_console_user"; then
    warn "refresh-services-menu: pbs rescan failed; the Services menu may stay stale until the next login"
  fi
else
  warn "refresh-services-menu: no console user session (headless/SSH); Services rescan skipped"
fi
