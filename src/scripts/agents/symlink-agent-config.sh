#!/usr/bin/env bash
# Sets up ~/.agents/ with per-entry symlinks into the resolved agents overlay dir.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/resolve-user-config.sh"
. "$SCRIPT_DIR/../lib/symlink-convergence.sh"

_as_repo_root="$1"
_as_username="$2"
# Skip exporting NUCLEUS_REPO_ROOT when the path is a Nix store snapshot —
# derive_repo_root() will fall back to the system repo-root file silently.
if [ -n "$_as_repo_root" ] && case "$_as_repo_root" in /nix/store/*) false ;; *) true ;; esac then
  export NUCLEUS_REPO_ROOT="$_as_repo_root"
fi

_as_agents_dir="$HOME/.agents"

# Ensure ~/.agents exists as a real (writable) directory.
if [ ! -d "$_as_agents_dir" ]; then
  mkdir "$_as_agents_dir"
  say -l agents-config "created $HOME/.agents"
elif [ -e "$_as_agents_dir" ] && [ ! -d "$_as_agents_dir" ]; then
  # Unexpected non-directory file: fail fast.
  die -l agents-config "$HOME/.agents exists but is not a directory — remove it and re-run apply."
fi

_nucleus_remove_stale_merged_symlinks \
  "$_as_agents_dir" "$_as_username" "agents" "agents-config" "skills pi-extensions"

_nucleus_converge_merged_config_symlinks \
  "$_as_username" "agents" "$_as_agents_dir" "agents-config" \
  "" "-e" \
  "is not a managed symlink — merge any wanted content into the source entry and remove it, then re-run apply." \
  "skills pi-extensions"

# Create the ~/.config/opencode/opencode.jsonc symlink to the repo-hosted
# user config. Resolved at activation time (rather than via Nix-level
# mkOutOfStoreSymlink) so the link still works after the repo root path
# changes between rebuilds.
mkdir -p "$HOME/.config/opencode"
if ! _as_opencode_source="$(resolve_user_config_file "$_as_username" "opencode" "opencode.jsonc")"; then
  die -l agents-config "cannot resolve the opencode.jsonc overlay source for user '$_as_username' — checked src/users/{$_as_username, default}/opencode/opencode.jsonc"
fi
_as_opencode_link="$HOME/.config/opencode/opencode.jsonc"
if [ -L "$_as_opencode_link" ]; then
  if [ "$(readlink "$_as_opencode_link")" != "$_as_opencode_source" ]; then
    rm "$_as_opencode_link"
  fi
elif [ -e "$_as_opencode_link" ]; then
  die -l agents-config "$_as_opencode_link exists and is not a managed symlink — remove or back it up, then re-run apply."
fi
if [ ! -e "$_as_opencode_link" ]; then
  ln -s "$_as_opencode_source" "$_as_opencode_link"
  say -l agents-config "linked $HOME/.config/opencode/opencode.jsonc"
fi
