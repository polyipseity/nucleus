# shellcheck shell=sh
# Obsidian settings merge: merges managed advanced-setting keys into
# obsidian.json while preserving app-owned vault metadata.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_moj_python3_bin="$1"
_moj_merge_script="$2"
_moj_settings_json="$3"

_obsidian_merge_json() {
  _python3_bin="$1"
  _python_script="$2"
  _settings_path="$3"
  _managed_json="$4"
  "$_python3_bin" "$_python_script" "$_settings_path" "$_managed_json"
}

case "$(uname -s)" in
  Darwin)
    _obsidian_settings_path="$HOME/Library/Application Support/obsidian/obsidian.json"
    ;;
  Linux)
    _obsidian_settings_path="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/obsidian.json"
    ;;
  *)
    exit 0
    ;;
esac

mkdir -p "$(dirname "$_obsidian_settings_path")"
_obsidian_merge_json "$_moj_python3_bin" "$_moj_merge_script" "$_obsidian_settings_path" "$_moj_settings_json"
