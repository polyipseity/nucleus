#!/usr/bin/env bash
# ---- refreshServicesMenu ---------------------------------------------------
# Refresh LaunchServices and pasteboard daemon caches so newly deployed
# Automator workflows and App bundles appear in the Services menu and
# Quick Actions immediately.
#
# Sourced functions: refresh_services_menu (macos-launch-services-lib.sh)
#
# This is the bundle subprocess equivalent of the inline activation fragment
# that previously used builtins.readFile + direct function call.  Sourcing the
# lib via SCRIPT_DIR eliminates Nix eval-time file reads.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/macos-launch-services-lib.sh
. "$SCRIPT_DIR/../lib/macos-launch-services-lib.sh"

refresh_services_menu
