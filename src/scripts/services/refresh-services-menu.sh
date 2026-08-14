#!/usr/bin/env bash
# ---- refreshServicesMenu ---------------------------------------------------
# Refresh LaunchServices and pasteboard daemon caches so newly deployed
# Automator workflows and App bundles appear in the Services menu and
# Quick Actions immediately.
#
# Sourced functions: refresh_services_menu (macos-launch-services.sh)

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/macos-launch-services.sh
. "$SCRIPT_DIR/../lib/macos-launch-services.sh"

refresh_services_menu
