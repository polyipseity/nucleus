#!/usr/bin/env bash
# Configure Finder sidebar favorites via mysides.
# Replaces the macos-configure-finder-sidebar inline activation block.
#
# Usage: configure-finder-sidebar <favorites-json> <jq-bin> <mysides-bin> <expected-order> <managed-count>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-finder-sidebar-lib.sh"

_favorites_json="$1"
_jq_bin="$2"
_mysides_bin="$3"
_expected_order="$4"
_managed_count="$5"

finder_configure_sidebar "$_favorites_json" "$_jq_bin" "$_mysides_bin" "$_expected_order" "$_managed_count"
