#!/usr/bin/env bash
# Symlinks Pi coding agent config files from ~/.agents/ into ~/.pi/agent/.
#
# Creates:
#   ~/.pi/agent/extensions/agents-bridge.ts → ~/.agents/extensions/agents-bridge.ts
#   ~/.pi/agent/settings.json                → ~/.agents/pi-settings.json
#
# Skills are handled natively by Pi (auto-discovered from ~/.agents/skills/ and
# .agents/skills/), so no symlink is needed for those.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

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

# --- Extension symlink ---
# Source: ~/.agents/extensions/agents-bridge.ts (deployed by symlink-agent-config.sh)
_spi_ext_source="$HOME/.agents/extensions/agents-bridge.ts"
_spi_ext_link="$_spi_extensions_dir/agents-bridge.ts"

if [ -L "$_spi_ext_link" ]; then
  if [ "$(readlink "$_spi_ext_link")" != "$_spi_ext_source" ]; then
    _nucleus_unprotect_symlink "pi-agent" "$_spi_ext_link"
    rm "$_spi_ext_link"
    ln -s "$_spi_ext_source" "$_spi_ext_link"
    _nucleus_protect_symlink "pi-agent" "$_spi_ext_link"
    say -l pi-agent "updated $_spi_ext_link -> $_spi_ext_source"
  fi
elif [ -e "$_spi_ext_link" ]; then
  die -l pi-agent "$_spi_ext_link exists and is not a managed symlink — remove it and re-run apply."
else
  if [ -e "$_spi_ext_source" ]; then
    ln -s "$_spi_ext_source" "$_spi_ext_link"
    _nucleus_protect_symlink "pi-agent" "$_spi_ext_link"
    say -l pi-agent "linked $_spi_ext_link -> $_spi_ext_source"
  else
    warn -l pi-agent "extension source not found: $_spi_ext_source — skipping symlink"
  fi
fi

# --- Settings symlink ---
# Source: ~/.agents/pi-settings.json (deployed by symlink-agent-config.sh)
_spi_settings_source="$HOME/.agents/pi-settings.json"
_spi_settings_link="$_spi_pi_dir/settings.json"

if [ -L "$_spi_settings_link" ]; then
  if [ "$(readlink "$_spi_settings_link")" != "$_spi_settings_source" ]; then
    _nucleus_unprotect_symlink "pi-agent" "$_spi_settings_link"
    rm "$_spi_settings_link"
    ln -s "$_spi_settings_source" "$_spi_settings_link"
    _nucleus_protect_symlink "pi-agent" "$_spi_settings_link"
    say -l pi-agent "updated $_spi_settings_link -> $_spi_settings_source"
  fi
elif [ -e "$_spi_settings_link" ]; then
  die -l pi-agent "$_spi_settings_link exists and is not a managed symlink — remove it and re-run apply."
else
  if [ -e "$_spi_settings_source" ]; then
    ln -s "$_spi_settings_source" "$_spi_settings_link"
    _nucleus_protect_symlink "pi-agent" "$_spi_settings_link"
    say -l pi-agent "linked $_spi_settings_link -> $_spi_settings_source"
  else
    warn -l pi-agent "settings source not found: $_spi_settings_source — skipping symlink"
  fi
fi
