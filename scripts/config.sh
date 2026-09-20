#!/usr/bin/env bash
# Manages runtime configuration for nucleus services.
# Config is stored at ~/.local/state/nucleus/config.json on every host (see
# script-authoring.instructions.md).
# Subcommands: get, set, list.

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# WHY: one canonical location on every host. Resolving this per-OS made the CLI disagree
# with scripts/config.ps1 and with the documented path, so automation reading the documented
# path would silently see no config at all.
CONFIG_FILE="$HOME/.local/state/nucleus/config.json"

usage() {
  usage_std "$(basename "$0")" "get [<section.key>]|set <section.key> <value>|list" "Manage runtime configuration for nucleus services."
  cat <<'EOF'
  get [<section.key>]       Print config value(s). Omit key to dump all.
  set <section.key> <val>   Set a config key (value is JSON-typed).
  list                      Print all config as flat key=value pairs.
EOF
}

require_command jq

# Default values for all known config keys.
# Used as fallback when file/key is absent, so users can discover available options.
DEFAULTS='{
  "camilladsp": {
    "enable": true,
    "heartbeat": true
  },
  "harness-approval": {
    "enable": false,
    "timeout-seconds": 120
  },
  "harness-drive": {
    "enable": true
  },
  "harness-notify": {
    "enable": true,
    "channels": ["telegram", "ntfy", "discord"],
    "max-chars": 1200
  }
}'

ensure_config_dir() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
}

# Merge user config over defaults, output merged JSON.
merge_config() {
  if [ -f "$CONFIG_FILE" ]; then
    jq -n --argjson defaults "$DEFAULTS" --argjson user "$(cat "$CONFIG_FILE")" '
      def deepMerge(a; b):
        if (a | type) == "object" and (b | type) == "object" then
          (a | keys) + (b | keys) | unique |
          reduce .[] as $k ({}; .[$k] = deepMerge(a[$k]; b[$k]))
        elif b == null then a
        else b
        end;
      deepMerge($defaults; $user)
    '
  else
    echo "$DEFAULTS"
  fi
}

# _key_path_json <section.key> — print the dot-separated key as a jq path array.
# Built with jq so a key containing a quote or backslash cannot produce invalid JSON.
_key_path_json() {
  jq -n --arg key "$1" '$key | split(".")'
}

cmd_get() {
  if [ $# -eq 0 ]; then
    merge_config
  else
    # WHY a path walk instead of a `.section.key // null` filter: jq's alternative
    # operator treats `false` as false-y, so `false // null` is null and an off
    # boolean printed nothing and exited 1 — indistinguishable from a missing key.
    # The walk fails only when a segment is absent, so `false` and `null` values
    # are printed while an unknown key keeps the "no output, exit 1" contract.
    path_json="$(_key_path_json "$1")"
    merged=$(merge_config)
    if ! val=$(printf '%s' "$merged" | jq -r --argjson path "$path_json" '
      reduce $path[] as $k (.; if type == "object" and has($k) then .[$k] else error("no such key") end)
    ' 2>/dev/null); then
      return 1
    fi
    printf '%s\n' "$val"
  fi
}

cmd_set() {
  if [ $# -lt 2 ]; then
    error "set requires a key and a value"
    usage >&2
    return 1
  fi
  ensure_config_dir

  key="$1"
  shift
  raw_value="$*"

  # Convert dot-separated key to jq path JSON array
  path_json="$(_key_path_json "$key")"

  # WHY `try/catch` and not `fromjson? // $raw`: jq's alternative operator treats a
  # parsed `false` (and `null`) as false-y, so `set <key> false` stored the string
  # "false" instead of the boolean. Only a parse failure should fall back to raw.
  if [ -f "$CONFIG_FILE" ]; then
    jq --argjson path "$path_json" --arg raw "$raw_value" '
      setpath($path; (try ($raw | fromjson) catch $raw))
    ' "$CONFIG_FILE"
  else
    echo '{}' | jq --argjson path "$path_json" --arg raw "$raw_value" '
      setpath($path; (try ($raw | fromjson) catch $raw))
    '
  fi >"${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

cmd_list() {
  # WHY `type != …` and not `scalars`: `paths(f)` keeps a leaf only when f yields
  # something truthy, so `paths(scalars)` dropped every `false` leaf and the
  # default-off flags were missing from the listing entirely.
  merge_config | jq -r '
    paths(type != "object" and type != "array") as $p
    | { key: ($p | join(".")), val: getpath($p) | tojson }
    | "\(.key)=\(.val)"
  '
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
get)
  shift
  cmd_get "$@"
  ;;
set)
  shift
  cmd_set "$@"
  ;;
list) cmd_list ;;
*)
  error "unknown command '${1:-}'"
  usage >&2
  exit 1
  ;;
esac
