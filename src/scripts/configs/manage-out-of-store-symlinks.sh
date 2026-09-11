#!/usr/bin/env bash
# Manage out-of-store symlinks (protect/unprotect/verify) using a JSON path manifest.
# Handles the inline logic from home.nix unprotect-out-of-store-symlinks /
# protect-out-of-store-symlinks / verify-managed-symlink-paths activation blocks.
#
# Usage: manage-out-of-store-symlinks (protect|unprotect|verify) <context> <paths-json> <jq-bin>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_action="$1"
_context="$2"
_paths_json="$3"
_jq_bin="$4"

_do_managed_paths() {
  _context="$1"
  _paths_json="$2"
  _jq_bin="$3"
  # Each entry is { path, writable ? false }. Writable entries are managed (still
  # unprotect-before update so a previously-immutable link is cleared once) but are
  # never hardened immutable, so apps can write through them. Non-writable entries
  # are hardened immutable (uchg/chattr +i) per the default managed-symlink contract.
  echo "$_paths_json" | "$_jq_bin" -r '.[] | [.path, (.writable // false)] | @tsv' | while IFS=$'\t' read -r _p _writable; do
    [ -n "$_p" ] || continue
    case "$_action" in
    protect)
      if [ "$_writable" = "true" ]; then
        # Writable managed symlink: clear any stale immutable flag, then leave writable.
        _nucleus_unprotect_symlink "$_context" "$_p"
      else
        _nucleus_protect_symlink "$_context" "$_p"
      fi
      ;;
    unprotect) _nucleus_unprotect_symlink "$_context" "$_p" ;;
    esac
  done
}

# verify — every managed path must exist once the post-linkGeneration seeders have
# run. Unprotect tolerates an absent path because it runs *before* those seeders;
# this action runs *after* them, so absence means the creating activation step did
# not converge and the application would silently read a nonexistent config. A
# dangling symlink is the same defect with the link left behind, so both are
# hard errors.
_do_verify() {
  _v_context="$1"
  _v_paths_json="$2"
  _v_jq_bin="$3"
  while IFS= read -r _v_path; do
    [ -n "$_v_path" ] || continue
    if [ -e "$_v_path" ]; then
      continue
    fi
    if [ -L "$_v_path" ]; then
      die -l "$_v_context" "managed symlink $_v_path is dangling; its target no longer exists"
    fi
    die -l "$_v_context" "managed path $_v_path does not exist after the seeders ran; its creating activation step did not converge"
  done < <(printf '%s' "$_v_paths_json" | "$_v_jq_bin" -r '.[].path')
}

case "$_action" in
protect | unprotect) _do_managed_paths "$_context" "$_paths_json" "$_jq_bin" ;;
verify) _do_verify "$_context" "$_paths_json" "$_jq_bin" ;;
*) die -l managed-symlinks "unknown action '$_action'; expected protect, unprotect or verify" ;;
esac
