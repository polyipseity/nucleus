#!/usr/bin/env bash
# Cursor extension bridge, called by home-manager activation
# symlink-cursor-extensions.
# Provides: _nucleus_protect_symlink, _nucleus_unprotect_symlink (from symlink-hardening.sh)

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_extension_store="$1"
source_extensions="$_extension_store/share/vscode/extensions"
cursor_extensions="$HOME/.cursor/extensions"

# Verify DIR is a real writable directory holding per-extension symlinks into
# the Nix-managed source tree. Cursor writes extensions.json inside it, and a
# whole-directory symlink into the store fails that with EACCES.
setup_cursor_extension_dir() {
  _sed_dir="$1"

  if [ -L "$_sed_dir" ]; then
    error -l "Cursor extensions" "$_sed_dir is a symlink; remove it, recreate a directory, and re-apply"
    return 1
  fi
  mkdir -p "$_sed_dir"

  # Trailing-slash glob matches real and symlinked directories only; the -d
  # guard covers an empty source without error.
  for _sed_src in "$source_extensions"/*/; do
    [ -d "$_sed_src" ] || continue
    _sed_src="${_sed_src%/}"
    _sed_ext_name="${_sed_src##*/}"
    _sed_link="$_sed_dir/$_sed_ext_name"

    if [ -L "$_sed_link" ]; then
      # Correct symlink → no-op; wrong target (e.g. after store upgrade) → replace.
      [ "$(readlink "$_sed_link")" = "$_sed_src" ] && continue
      _nucleus_unprotect_symlink "Cursor" "$_sed_link"
      rm "$_sed_link"
    elif [ -e "$_sed_link" ]; then
      # Non-symlink entry (user-installed extension): leave untouched.
      continue
    fi

    ln -s "$_sed_src" "$_sed_link"
    _nucleus_protect_symlink "Cursor" "$_sed_link"
  done

  # Prune everything outside the managed set, including real directories and
  # files, so the bridge is the sole source of truth. Bare-star glob, no
  # trailing slash, so broken symlinks match too.
  for _sed_existing in "$_sed_dir"/*; do
    [ -e "$_sed_existing" ] || [ -L "$_sed_existing" ] || continue
    _sed_ext_name="${_sed_existing##*/}"
    [ -e "$source_extensions/$_sed_ext_name" ] && continue
    if [ -L "$_sed_existing" ]; then
      _nucleus_unprotect_symlink "Cursor" "$_sed_existing"
    fi
    rm -rf "$_sed_existing"
  done
  # WHY: .obsolete is Cursor's deferred-deletion marker and a dotfile, so the
  # glob above misses it.
  rm -f "$_sed_dir/.obsolete"

  # WHY: Cursor trusts extensions.json when present and rescans only when it is
  # absent, so a stale manifest would hide newly added extensions.
  rm -f "$_sed_dir/extensions.json"
}

mkdir -p "$HOME/.cursor"
setup_cursor_extension_dir "$cursor_extensions"
