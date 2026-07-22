#!/usr/bin/env bash
# Manage out-of-store symlinks (protect/unprotect) using a JSON path manifest.
# Handles the inline logic from home.nix unprotectOutOfStoreSymlinks /
# protectOutOfStoreSymlinks activation blocks.
#
# Usage: manage-out-of-store-symlinks (protect|unprotect) <context> <paths-json> <jq-bin>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

_action="$1"
_context="$2"
_paths_json="$3"
_jq_bin="$4"

_do_managed_paths() {
  _context="$1"
  _paths_json="$2"
  _jq_bin="$3"
  echo "$_paths_json" | "$_jq_bin" -r '.[]' | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    case "$_action" in
      protect) _nucleus_protect_symlink "$_context" "$_p" ;;
      unprotect) _nucleus_unprotect_symlink "$_context" "$_p" ;;
    esac
  done
}

_do_managed_paths "$_context" "$_paths_json" "$_jq_bin"
