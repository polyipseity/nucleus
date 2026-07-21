# shellcheck shell=sh
# Obsidian settings merge: merges managed advanced-setting keys into
# obsidian.json while preserving app-owned vault metadata.
# Variables below are substituted via Nix replaceStrings at build time.
_obsidian_merge_json() {
  _python3_bin="$1"
  _python_script="$2"
  _settings_path="$3"
  _managed_json="$4"
  "$_python3_bin" "$_python_script" "$_settings_path" "$_managed_json"
}

set -eu

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
_obsidian_merge_json "__PYTHON3_BIN__" "__OBSIDIAN_MERGE_JSON_PY__" "$_obsidian_settings_path" __OBSIDIAN_SETTINGS_JSON__
