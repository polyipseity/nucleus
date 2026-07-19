# shellcheck shell=sh
# Obsidian settings merge: merges managed advanced-setting keys into
# obsidian.json while preserving app-owned vault metadata.
# Tokens: __PYTHON_SCRIPT__, __PYTHON3_BIN__, __OBSIDIAN_SETTINGS_JSON__
#   (replaced by Nix replaceStrings).
#
# Usage: _obsidian_merge_json <python3_bin> <settings_path> <managed_json>
_obsidian_merge_json() {
  _python3_bin="$1"
  _settings_path="$2"
  _managed_json="$3"
  "$_python3_bin" - "$_settings_path" "$_managed_json" <<'PYEOF'
__PYTHON_SCRIPT__
PYEOF
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
_obsidian_merge_json "__PYTHON3_BIN__" "$_obsidian_settings_path" "__OBSIDIAN_SETTINGS_JSON__"
