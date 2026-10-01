#!/usr/bin/env bash
# Manage out-of-store symlinks (protect/unprotect/verify) from a JSON path
# manifest, covering what home.nix activation blocks used to inline.
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
  # Each entry is { path, writable ? false }. A writable entry is still managed,
  # so an immutable link is cleared once, but is never hardened so apps can write
  # through it. A non-writable entry is hardened immutable (uchg/chattr +i).
  echo "$_paths_json" | "$_jq_bin" -r '.[] | [.path, (.writable // false)] | @tsv' | while IFS=$'\t' read -r _p _writable; do
    [ -n "$_p" ] || continue
    case "$_action" in
    protect)
      if [ "$_writable" = "true" ]; then
        # Writable link: clear a stale immutable flag, then leave it writable.
        _nucleus_unprotect_symlink "$_context" "$_p"
      else
        _nucleus_protect_symlink "$_context" "$_p"
      fi
      ;;
    unprotect) _nucleus_unprotect_symlink "$_context" "$_p" ;;
    esac
  done
}

# verify runs after the post-linkGeneration seeders, so an absent path means the
# creating step did not converge and the app would read a nonexistent config.
# Unprotect tolerates absence because it runs before those seeders. A dangling
# symlink is the same defect with the link left behind, so both are hard errors.
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
