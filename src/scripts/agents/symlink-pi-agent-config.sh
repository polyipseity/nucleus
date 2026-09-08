#!/usr/bin/env bash
# Creates method-1 (writable) symlinks from ~/.pi/agent/ into the live repo.
#
# Creates:
#   ~/.pi/agent/extensions/  → <live-root>/src/users/default/agents/pi-extensions/
#   ~/.pi/agent/settings.json → <live-root>/src/users/default/agents/pi-settings.json
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
if [ -n "$_spi_repo_root" ] && case "$_spi_repo_root" in /nix/store/*) false;; *) true;; esac; then
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
