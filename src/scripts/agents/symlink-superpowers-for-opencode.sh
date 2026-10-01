#!/usr/bin/env bash
# Creates ~/.opencode/plugins/superpowers -> the Nix store superpowers plugin.
# The plugin is fetched via builtins.fetchGit and symlinked to
# <nucleusUserRoot>/plugins/superpowers, so this is the method-1 symlink from
# there. Paths come from derive_nucleus_user_root().
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_spo_superpowers_plugin="$(derive_nucleus_user_root)/plugins/superpowers/.opencode/plugins/superpowers.js"
_spo_link_dir="$HOME/.opencode/plugins"
_spo_link="$_spo_link_dir/superpowers"

if [ ! -d "$_spo_link_dir" ]; then
  mkdir -p "$_spo_link_dir"
  say -l opencode-superpowers "created $_spo_link_dir"
fi

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
