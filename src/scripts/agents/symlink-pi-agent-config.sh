#!/usr/bin/env bash
# Creates method-1 (writable) symlinks from ~/.pi/agent/ into the live repo.
#
# Creates:
#   ~/.pi/agent/extensions/  → <live-root>/src/users/default/agents/pi-extensions/
#   ~/.pi/agent/settings.json → <live-root>/src/users/default/agents/pi-settings.json
#   ~/.pi/agent/extensions/superpowers.ts → Nix store superpowers plugin
#
# Skills are handled natively by Pi (auto-discovered from ~/.agents/skills/ and
# .agents/skills/), so no symlink is needed for those.
#
# Uses seed-writable-symlink.sh to resolve the LIVE repo root at activation
# time, so edits to source files propagate immediately without re-apply.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_spi_repo_root="$1"
_spi_username="$2"
# Skip exporting NUCLEUS_REPO_ROOT when the path is a Nix store snapshot —
# derive_repo_root() will fall back to the system repo-root file silently.
if [ -n "$_spi_repo_root" ] && case "$_spi_repo_root" in /nix/store/*) false ;; *) true ;; esac then
  export NUCLEUS_REPO_ROOT="$_spi_repo_root"
fi

_spi_pi_dir="$HOME/.pi/agent"

# Ensure ~/.pi/agent/ exists.
if [ ! -d "$_spi_pi_dir" ]; then
  mkdir -p "$_spi_pi_dir"
  say -l pi-agent "created $_spi_pi_dir"
fi

# --- Extensions symlink (method 1: writable, live repo) ---
"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_pi_dir/extensions" \
  "src/users/default/agents/pi-extensions"

# --- Settings symlink (method 1: writable, live repo) ---
"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_pi_dir/settings.json" \
  "src/users/default/agents/pi-settings.json"

# --- Superpowers extension symlink (method 1: Nix store target) ---
# The superpowers plugin is fetched via builtins.fetchGit and symlinked to
# <nucleus user root>/plugins/superpowers. We create a method-1 symlink
# from ~/.pi/agent/extensions/superpowers.ts to the Nix store target.
# The USER root is host-specific, so it comes from derive_nucleus_user_root
# (macOS ~/Library/Application Support/nucleus, NixOS ~/.local/share/nucleus).
_spi_superpowers_ext="$(derive_nucleus_user_root)/plugins/superpowers/.pi/extensions/superpowers.ts"
_spi_superpowers_link="$_spi_pi_dir/extensions/superpowers.ts"
if [ -L "$_spi_superpowers_link" ]; then
  if [ "$(readlink "$_spi_superpowers_link")" != "$_spi_superpowers_ext" ]; then
    rm "$_spi_superpowers_link"
  fi
elif [ -e "$_spi_superpowers_link" ]; then
  warn -l pi-agent "$_spi_superpowers_link exists and is not a managed symlink — skipping"
fi
if [ ! -e "$_spi_superpowers_link" ] && [ -e "$_spi_superpowers_ext" ]; then
  ln -s "$_spi_superpowers_ext" "$_spi_superpowers_link"
  say -l pi-agent "linked $_spi_superpowers_link -> $_spi_superpowers_ext"
fi
