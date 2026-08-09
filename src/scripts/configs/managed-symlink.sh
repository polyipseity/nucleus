#!/usr/bin/env bash
# Unified protect/unprotect symlink wrapper for activation scripts.
# Replaces ~10+ near-identical inline wrappers across the codebase.
#
# Usage: managed-symlink (protect|unprotect) <context> <path>
#
# Sources symlink-hardening.sh via SCRIPT_DIR at runtime.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_action="$1"
_context="$2"
_path="$3"

case "$_action" in
protect)
  _nucleus_protect_symlink "$_context" "$_path"
  ;;
unprotect)
  _nucleus_unprotect_symlink "$_context" "$_path"
  ;;
*)
  echo "managed-symlink: unknown action '$_action' (use protect|unprotect)" >&2
  exit 1
  ;;
esac
