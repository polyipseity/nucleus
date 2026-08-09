#!/usr/bin/env bash
# Manages runtime configuration for nucleus services.
# Config is stored in ~/.local/state/nucleus/config.json.
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

CONFIG_FILE="${HOME}/.local/state/nucleus/config.json"

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
    "heartbeat": true
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

cmd_get() {
  if [ $# -eq 0 ]; then
    merge_config
  else
    # Convert "section.key" to jq filter ".section.key // null"
    IFS='.' read -r -a parts <<<"$1"
    filter="."
    for part in "${parts[@]}"; do
      filter+=" | .\"$part\""
    done
    filter+=" // null"
    merged=$(merge_config)
    val=$(echo "$merged" | jq -r "$filter" 2>/dev/null || echo "null")
    if [ "$val" = "null" ]; then
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
  IFS='.' read -r -a parts <<<"$key"
  path_json='['
  sep=''
  for part in "${parts[@]}"; do
    path_json+="${sep}\"${part}\""
    sep=', '
  done
  path_json+=']'

  if [ -f "$CONFIG_FILE" ]; then
    jq --argjson path "$path_json" --arg raw "$raw_value" '
      setpath($path; ($raw | fromjson? // $raw))
    ' "$CONFIG_FILE"
  else
    echo '{}' | jq --argjson path "$path_json" --arg raw "$raw_value" '
      setpath($path; ($raw | fromjson? // $raw))
    '
  fi >"${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

cmd_list() {
  merge_config | jq -r '
    paths(scalars) as $p
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
