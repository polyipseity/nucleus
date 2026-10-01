#!/usr/bin/env bash
# VS Code extension bridge activation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_extension_store="$1"
source_extensions="$_extension_store/share/vscode/extensions"
stable_extensions="$HOME/.vscode/extensions"
insiders_extensions="$HOME/.vscode-insiders/extensions"

# setup_extension_dir CHANNEL_EXTENSIONS
# WHY a real directory: VS Code writes extensions.json inside it, so a
# whole-directory symlink into the immutable Nix store fails with EACCES.
# Non-symlink entries are user-installed extensions and stay untouched; the
# bridge is otherwise the sole source of truth for the directory contents.
setup_extension_dir() {
  _sed_dir="$1"

  if [ -L "$_sed_dir" ]; then
    error -l "VS Code extensions" "$_sed_dir is a symlink; remove it, recreate a directory, and re-apply"
    return 1
  fi
  mkdir -p "$_sed_dir"

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

  # Prune everything outside the Nix-managed set. A bare-star glob (no
  # trailing /) also catches broken symlinks.
  for _sed_existing in "$_sed_dir"/*; do
    [ -e "$_sed_existing" ] || [ -L "$_sed_existing" ] || continue
    _sed_ext_name="${_sed_existing##*/}"
    [ -e "$source_extensions/$_sed_ext_name" ] && continue
    if [ -L "$_sed_existing" ]; then
      _nucleus_unprotect_symlink "VS Code" "$_sed_existing"
    fi
    rm -rf "$_sed_existing"
  done
  # .obsolete is a dotfile, so the glob above misses it.
  rm -f "$_sed_dir/.obsolete"

  # WHY delete extensions.json: VS Code derives it from a directory scan only
  # when absent, and trusts a stale file otherwise, hiding new extensions.
  rm -f "$_sed_dir/extensions.json"
}

mkdir -p "$HOME/.vscode"
setup_extension_dir "$stable_extensions"

mkdir -p "$HOME/.vscode-insiders"
setup_extension_dir "$insiders_extensions"
