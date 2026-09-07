#!/usr/bin/env bash
# Creates method-1 (writable) symlinks from ~/.pi/agent/ into the live repo.
#
# Creates:
#   ~/.pi/agent/extensions/agents-bridge.ts → <live-root>/src/users/default/agents/extensions/agents-bridge.ts
#   ~/.pi/agent/settings.json                → <live-root>/src/users/default/agents/pi-settings.json
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
if [ -n "$_spi_repo_root" ]; then
  export NUCLEUS_REPO_ROOT="$_spi_repo_root"
fi

_spi_pi_dir="$HOME/.pi/agent"

# Ensure ~/.pi/agent/ exists.
if [ ! -d "$_spi_pi_dir" ]; then
  mkdir -p "$_spi_pi_dir"
  say -l pi-agent "created $_spi_pi_dir"
fi

# Ensure ~/.pi/agent/extensions/ exists for the extension symlink.
_spi_extensions_dir="$_spi_pi_dir/extensions"
if [ ! -d "$_spi_extensions_dir" ]; then
  mkdir -p "$_spi_extensions_dir"
  say -l pi-agent "created $_spi_extensions_dir"
fi

# --- Extension symlink (method 1: writable, live repo) ---
"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_extensions_dir/agents-bridge.ts" \
  "src/users/default/agents/extensions/agents-bridge.ts"

# --- Settings symlink (method 1: writable, live repo) ---
"$SCRIPT_DIR/../configs/seed-writable-symlink.sh" \
  "$_spi_pi_dir/settings.json" \
  "src/users/default/agents/pi-settings.json"
