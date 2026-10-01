#!/usr/bin/env bash
# Provision SteamCMD at RimSort's expected steamcmd_install_path, so the app
# does not download it at runtime. RimSort checks for the executable under
# <steamcmd_install_path>/steamcmd/<exe> and does not use PATH.
#
# macOS: symlink <prefix>/steamcmd to the store's share/steamcmd holding the
# native binary. NixOS: a directory with steamcmd.sh symlinked to the store
# wrapper, which invokes steam-run (FHS) internally.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_ps_python3_bin="$1"
_ps_steamcmd_nix_path="$2"
_ps_rimsort_settings_json="$3"

# Resolve steamcmd_install_path from the merged RimSort settings JSON.
_ps_steamcmd_prefix="$("$_ps_python3_bin" "$SCRIPT_DIR/provision-steamcmd.py" "$_ps_rimsort_settings_json")"

# Nothing to do when empty: the Windows host handles this through PowerShell.
if [ -z "$_ps_steamcmd_prefix" ]; then
  exit 0
fi

_ps_steamcmd_prefix="${_ps_steamcmd_prefix#\~}"
_ps_steamcmd_prefix="${HOME}${_ps_steamcmd_prefix}"

_ps_steamcmd_dir="$_ps_steamcmd_prefix/steamcmd"

case "$(uname -s)" in
Darwin)
  _ps_store_bins="$_ps_steamcmd_nix_path/share/steamcmd"
  if [ -L "$_ps_steamcmd_dir" ]; then
    rm -f "$_ps_steamcmd_dir"
  elif [ -d "$_ps_steamcmd_dir" ]; then
    rm -rf "$_ps_steamcmd_dir"
  fi
  ln -s "$_ps_store_bins" "$_ps_steamcmd_dir"
  ;;
Linux)
  # WHY symlink steamcmd.sh: RimSort looks for the executable at that exact name.
  mkdir -p "$_ps_steamcmd_dir"
  ln -sf "$_ps_steamcmd_nix_path/bin/steamcmd" "$_ps_steamcmd_dir/steamcmd.sh"
  ;;
esac
