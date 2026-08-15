#!/usr/bin/env bash
# VS Code extension bridge activation.
# Called by home-manager activation symlink-vscode-extensions.
# Provides: _nucleus_protect_symlink, _nucleus_unprotect_symlink (from symlink-hardening.sh)

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_extension_store="$1"
source_extensions="$_extension_store/share/vscode/extensions"
stable_extensions="$HOME/.vscode/extensions"
insiders_extensions="$HOME/.vscode-insiders/extensions"

# setup_extension_dir CHANNEL_EXTENSIONS
# Ensures CHANNEL_EXTENSIONS is a real writable directory containing
# per-extension symlinks into the Nix-managed source tree.  VS Code must
# write extensions.json inside this directory; a whole-directory symlink
# to the immutable Nix store prevents that with EACCES.
#
# Algorithm:
#   1. Fail if CHANNEL_EXTENSIONS is a symlink (fix manually per MANUAL.md).
#   2. Add a per-extension symlink for every entry under source_extensions.
#      Correct symlinks → no-op; wrong symlinks → replaced; non-symlinks
#      (user-installed extensions) → left untouched.
#   3. Prune all entries not in the Nix-managed extension set (both stale
#      symlinks and non-managed real directories/files) and remove
#      .obsolete (VS Code deferred-deletion dotfile).
#   4. Remove extensions.json so VS Code rescans the directory on next
#      invocation.  When absent, VS Code derives the manifest from the
#      directory; when present it trusts the file and skips the scan.
setup_extension_dir() {
  _sed_dir="$1"

  if [ -L "$_sed_dir" ]; then
    error -l "VS Code extensions" "$_sed_dir is a symlink; remove it, recreate a directory, and re-apply"
    return 1
  fi
  mkdir -p "$_sed_dir"

  # Add a per-extension symlink for each Nix-managed extension.
  # Trailing-slash glob only matches actual directories (and symlinked dirs);
  # the -d guard handles the empty-source no-op without error.
  for _sed_src in "$source_extensions"/*/; do
    [ -d "$_sed_src" ] || continue
    _sed_src="${_sed_src%/}"
    _sed_ext_name="${_sed_src##*/}"
    _sed_link="$_sed_dir/$_sed_ext_name"

    if [ -L "$_sed_link" ]; then
      # Correct symlink → no-op; wrong target (e.g. after store upgrade) → replace.
      [ "$(readlink "$_sed_link")" = "$_sed_src" ] && continue
      _nucleus_unprotect_symlink "VS Code" "$_sed_link"
      rm "$_sed_link"
    elif [ -e "$_sed_link" ]; then
      # Non-symlink entry (user-installed extension): leave untouched.
      continue
    fi

    ln -s "$_sed_src" "$_sed_link"
    _nucleus_protect_symlink "VS Code" "$_sed_link"
  done

  # Step 3: prune all entries not in the Nix-managed extension set.
  # Removes both stale symlinks and non-managed real directories/files so the
  # bridge is the sole source of truth for the directory contents.  Use a
  # bare-star glob (no trailing /) to catch broken symlinks as well.
  for _sed_existing in "$_sed_dir"/*; do
    [ -e "$_sed_existing" ] || [ -L "$_sed_existing" ] || continue
    _sed_ext_name="${_sed_existing##*/}"
    [ -e "$source_extensions/$_sed_ext_name" ] && continue
    if [ -L "$_sed_existing" ]; then
      _nucleus_unprotect_symlink "VS Code" "$_sed_existing"
    fi
    rm -rf "$_sed_existing"
  done
  # .obsolete is a VS Code deferred-deletion marker written as a dotfile
  # (not matched by the * glob above); remove it unconditionally so the
  # bridge fully owns the directory state.
  rm -f "$_sed_dir/.obsolete"

  # Step 4: remove extensions.json so VS Code rescans the directory on
  # next invocation and derives a fresh manifest from the symlink set.
  # VS Code creates this file from a directory scan when absent; when the
  # file is present VS Code trusts it and skips the scan, so a stale file
  # (e.g. from a previous apply with fewer managed extensions) would make
  # newly added extensions invisible.  The bridge owns the directory
  # state; extensions.json is a derived artifact, not a source of truth.
  rm -f "$_sed_dir/extensions.json"
}

mkdir -p "$HOME/.vscode"
setup_extension_dir "$stable_extensions"

mkdir -p "$HOME/.vscode-insiders"
setup_extension_dir "$insiders_extensions"
