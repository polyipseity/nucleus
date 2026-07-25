#!/usr/bin/env bash
# Configure iCloud exclusion markers on matching directories.
# Replaces the macos-configure-icloud-exclusions inline activation block.
#
# Usage: configure-icloud-exclusions <jq-bin> <find-bin> <excluded-dirs-json> <managed-roots-json>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-icloud-exclusions-lib.sh"

_jq_bin="$1"
_find_bin="$2"
_excluded_dirs_json="$3"
_managed_roots_json="$4"

apply_exclusions "$_jq_bin" "$_find_bin" "$_excluded_dirs_json" "$_managed_roots_json"
