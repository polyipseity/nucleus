#!/usr/bin/env bash
# RimSort settings merge: merges managed instance keys (paths, Steam
# integration flags) into settings.json while preserving app-owned
# theme, sorting, and window-state settings.
#
# Method 3 (merge) — RimSort owns settings.json and overwrites it on
# every save. A symlink would let app-owned writes reach the repo file.
# Merge injects managed keys into instances.Default while preserving
# all other settings.

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
