#!/usr/bin/env bash
# Creates method-1 symlink for OpenCode superpowers plugin.
#
# Creates:
#   ~/.opencode/plugins/superpowers → Nix store superpowers plugin
#
# The superpowers plugin is fetched via builtins.fetchGit and symlinked to
# ~/.local/share/nucleus/plugins/superpowers. This script creates a method-1
# symlink from ~/.opencode/plugins/superpowers to the Nix store target.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_spo_superpowers_plugin="$HOME/.local/share/nucleus/plugins/superpowers/.opencode/plugins/superpowers.js"
_spo_link_dir="$HOME/.opencode/plugins"
_spo_link="$_spo_link_dir/superpowers"

# Ensure ~/.opencode/plugins/ exists.
if [ ! -d "$_spo_link_dir" ]; then
  mkdir -p "$_spo_link_dir"
  say -l opencode-superpowers "created $_spo_link_dir"
fi

# Create method-1 symlink if target exists.
if [ -L "$_spo_link" ]; then
  if [ "$(readlink "$_spo_link")" != "$_spo_superpowers_plugin" ]; then
    rm "$_spo_link"
  fi
elif [ -e "$_spo_link" ]; then
  warn -l opencode-superpowers "$_spo_link exists and is not a managed symlink — skipping"
fi
if [ ! -e "$_spo_link" ] && [ -e "$_spo_superpowers_plugin" ]; then
  ln -s "$_spo_superpowers_plugin" "$_spo_link"
  say -l opencode-superpowers "linked $_spo_link -> $_spo_superpowers_plugin"
fi
