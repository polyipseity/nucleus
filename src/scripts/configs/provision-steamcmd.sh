#!/usr/bin/env bash
# SteamCMD provisioning: creates the directory structure and binary at
# RimSort's expected steamcmd_install_path so the app does not need to
# download SteamCMD at runtime.
#
# RimSort checks for the executable at <steamcmd_install_path>/steamcmd/<exe>
# but does not use PATH — the file must exist at the expected path.
#
# On macOS: symlinks <prefix>/steamcmd to the Nix store's share/steamcmd
# directory containing the native macOS SteamCMD binary.
#
# On NixOS: creates <prefix>/steamcmd/ as a directory with a symlink
# steamcmd.sh → Nix store's steamcmd wrapper which invokes steam-run
# (FHS environment) internally.
#
# Called by home-manager activation provision-steamcmd.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_ps_python3_bin="$1"
_ps_steamcmd_nix_path="$2"
_ps_rimsort_settings_json="$3"

# Resolve steamcmd_install_path from the merged RimSort settings JSON.
_ps_steamcmd_prefix="$("$_ps_python3_bin" "$SCRIPT_DIR/provision-steamcmd.py" "$_ps_rimsort_settings_json")"

# Nothing to do if the path is empty (Windows host — handled by PowerShell).
if [ -z "$_ps_steamcmd_prefix" ]; then
  exit 0
fi

# Expand ~ to $HOME.
_ps_steamcmd_prefix="${_ps_steamcmd_prefix#\$HOME}"
_ps_steamcmd_prefix="${HOME}${_ps_steamcmd_prefix}"

_ps_steamcmd_dir="$_ps_steamcmd_prefix/steamcmd"

case "$(uname -s)" in
Darwin)
  # Symlink the entire steamcmd directory to the Nix store's share/steamcmd.
  # The macOS native binary needs no FHS wrapper.
  _ps_store_bins="$_ps_steamcmd_nix_path/share/steamcmd"
  if [ -L "$_ps_steamcmd_dir" ]; then
    rm -f "$_ps_steamcmd_dir"
  elif [ -d "$_ps_steamcmd_dir" ]; then
    rm -rf "$_ps_steamcmd_dir"
  fi
  ln -s "$_ps_store_bins" "$_ps_steamcmd_dir"
  ;;
Linux)
  # The Nix store's steamcmd wrapper (bin/steamcmd) handles steam-run
  # and file deployment internally.  Symlink steamcmd.sh to it so
  # RimSort finds the executable at its expected path.
  mkdir -p "$_ps_steamcmd_dir"
  ln -sf "$_ps_steamcmd_nix_path/bin/steamcmd" "$_ps_steamcmd_dir/steamcmd.sh"
  ;;
esac
