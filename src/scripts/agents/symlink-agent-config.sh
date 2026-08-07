#!/usr/bin/env bash
# Sets up ~/.agents/ with per-entry symlinks into the resolved agents overlay dir.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/symlink-convergence.sh"
. "$SCRIPT_DIR/../lib/resolve-user-config.sh"

_as_repo_root="$1"
_as_username="$2"
_as_agents_source="$(resolve_user_config_dir "$_as_username" "agents")"
if [ ! -d "$_as_agents_source" ]; then
  echo "agents-config: agents config dir not found: $_as_agents_source" >&2
  exit 1
fi

_as_agents_dir="$HOME/.agents"

# Ensure ~/.agents exists as a real (writable) directory.
if [ ! -d "$_as_agents_dir" ]; then
  mkdir "$_as_agents_dir"
  echo "agents-config: created $HOME/.agents"
elif [ -e "$_as_agents_dir" ] && [ ! -d "$_as_agents_dir" ]; then
  # Unexpected non-directory file: fail fast.
  echo "agents-config: $HOME/.agents exists but is not a directory — remove it and re-run apply." >&2
  exit 1
fi

_nucleus_remove_stale_symlinks \
  "$_as_agents_dir" "$_as_agents_source" "agents-config" "skills"

_nucleus_converge_symlinks \
  "$_as_agents_source" "$_as_agents_dir" "agents-config" \
  "" "-e" \
  "is not a managed symlink — merge any wanted content into the source entry and remove it, then re-run apply." \
  "skills"

# Create the ~/.config/opencode/opencode.jsonc symlink to the repo-hosted
# user config. Resolved at activation time (rather than via Nix-level
# mkOutOfStoreSymlink) so the link still works after the repo root path
# changes between rebuilds.
mkdir -p "$HOME/.config/opencode"
_as_opencode_source="$(resolve_user_config_file "$_as_username" "agents" "opencode.user.jsonc")"
_as_opencode_link="$HOME/.config/opencode/opencode.jsonc"
if [ -L "$_as_opencode_link" ]; then
  if [ "$(readlink "$_as_opencode_link")" != "$_as_opencode_source" ]; then
    rm "$_as_opencode_link"
  fi
elif [ -e "$_as_opencode_link" ]; then
  echo "agents-config: $_as_opencode_link exists and is not a managed symlink — remove or back it up, then re-run apply." >&2
  exit 1
fi
if [ ! -e "$_as_opencode_link" ]; then
  ln -s "$_as_opencode_source" "$_as_opencode_link"
  echo "agents-config: linked $HOME/.config/opencode/opencode.jsonc"
fi
