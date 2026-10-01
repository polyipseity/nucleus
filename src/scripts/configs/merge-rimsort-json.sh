#!/usr/bin/env bash
# Merge managed instance keys (paths, Steam integration flags) into
# RimSort's settings.json, preserving app-owned theme, sorting and window state.
#
# WHY merge and not a symlink (method 3): RimSort owns the file and rewrites it
# on every save, so a symlink would let app-owned writes reach the repo.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_mrs_python3_bin="$1"
_mrs_settings_json="$2"

_rimsort_merge_json() {
  _python3_bin="$1"
  _settings_path="$2"
  _managed_json="$3"
  "$_python3_bin" "$SCRIPT_DIR/merge-rimsort-json.py" "$_settings_path" "$_managed_json"
}

case "$(uname -s)" in
Darwin)
  _rimsort_settings_path="$HOME/Library/Application Support/RimSort/settings.json"
  ;;
Linux)
  _rimsort_settings_path="${XDG_DATA_HOME:-$HOME/.local/share}/RimSort/settings.json"
  ;;
*)
  exit 0
  ;;
esac

mkdir -p "$(dirname "$_rimsort_settings_path")"
_rimsort_merge_json "$_mrs_python3_bin" "$_rimsort_settings_path" "$_mrs_settings_json"

# WHY: Steam creates the workshop folder only after the first mod download, and
# without it RimSort disables Steam integration on startup.
_workshop_folder="$($_mrs_python3_bin -c "
import json, os, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
path = data.get('instances', {}).get('Default', {}).get('workshop_folder', '')
print(os.path.expanduser(path))
" "$_rimsort_settings_path")"
if [ -n "$_workshop_folder" ]; then
  mkdir -p "$_workshop_folder"

  # WHY the ACF: Steam writes it on first game launch or workshop download, and
  # RimSort validates the workshop folder against it.
  _acf_file="$($_mrs_python3_bin -c "
import json, os, sys
from pathlib import Path
with open(sys.argv[1]) as f:
    data = json.load(f)
path = data.get('instances', {}).get('Default', {}).get('workshop_folder', '')
print(Path(os.path.expanduser(path)).parent.parent / 'appworkshop_294100.acf')
" "$_rimsort_settings_path")"
  if [ -n "$_acf_file" ] && [ ! -f "$_acf_file" ]; then
    mkdir -p "$(dirname "$_acf_file")"
    printf '"AppWorkshop"\n{\n\t"appid"\t\t\t"294100"\n\t"SizeOnDisk"\t\t"0"\n\t"needsUpdate"\t\t"0"\n\t"TimeLastUpdated"\t"0"\n\t"WorkshopItemsInstalled"\n\t{\n\t}\n}\n' >"$_acf_file"
  fi
fi
