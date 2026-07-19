# shellcheck shell=sh
# Obsidian settings merge: merges managed advanced-setting keys into
# obsidian.json while preserving app-owned vault metadata.
# Token: __PYTHON_SCRIPT__ (replaced by Nix replaceStrings with the Python code).
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
