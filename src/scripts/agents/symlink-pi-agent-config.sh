#!/usr/bin/env bash
# Creates method-1 (writable) symlinks from ~/.pi/ into the live repo:
#   ~/.pi/agent/extensions/    → <live-root>/src/users/default/pi/extensions/
#   ~/.pi/agent/settings.json  → <live-root>/src/users/default/pi/settings.json
#   ~/.pi/agent/npm/bunfig.toml → <live-root>/src/users/default/pi/bunfig.toml
#   ~/.pi/web-search.json       → <live-root>/src/users/default/pi/web-search.json
#   ~/.pi/agent/extensions/superpowers.ts → Nix store superpowers plugin
#
# Skills are handled natively by Pi (auto-discovered from ~/.agents/skills/ and
# .agents/skills/), so no symlink is needed for those.
#
# seed-writable-symlink.sh resolves the live repo root at activation time, so edits to
# source files propagate without a re-apply.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_spi_repo_root="$1"
_spi_username="$2"
# Skip exporting NUCLEUS_REPO_ROOT for a Nix store snapshot: derive_repo_root() then falls
# back to the system repo-root file silently.
if [ -n "$_spi_repo_root" ] && case "$_spi_repo_root" in /nix/store/*) false ;; *) true ;; esac then
  export NUCLEUS_REPO_ROOT="$_spi_repo_root"
fi

_spi_pi_dir="$HOME/.pi/agent"

if [ ! -d "$_spi_pi_dir" ]; then
  mkdir -p "$_spi_pi_dir"
  say -l pi-agent "created $_spi_pi_dir"
fi

"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_pi_dir/extensions" \
  "src/users/default/pi/extensions"

"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_pi_dir/settings.json" \
  "src/users/default/pi/settings.json"

# WHY: Pi extensions need the hoisted linker for Node.js module resolution. The global
# bunfig.toml uses isolated (right for global CLI tools), but pi's npm directory needs hoisted
# so dependencies land in top-level node_modules/.
"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_pi_dir/npm/bunfig.toml" \
  "src/users/default/pi/bunfig.toml"

# WHY: pi-web-access reads ~/.pi/web-search.json (legacy dir), not ~/.pi/agent/web-search.json.
# See getWebSearchConfigDir() in pi-web-access utils.ts.
"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$HOME/.pi/web-search.json" \
  "src/users/default/pi/web-search.json"

# Method-1 symlink from ~/.pi/agent/extensions/superpowers.ts to the Nix store target. The
# plugin is fetched via builtins.fetchGit and lives at <nucleus user root>/plugins/superpowers;
# the USER root is host-specific, so derive_nucleus_user_root resolves it.
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
