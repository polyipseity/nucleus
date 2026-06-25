#!/usr/bin/env bash
# Manages runtime configuration for nucleus services.
# Config is stored in ~/.local/state/nucleus/config.json.
# Subcommands: get, set, list.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

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

ensure_config_dir() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
}

cmd_get() {
  if [ ! -f "$CONFIG_FILE" ]; then
    return 0
  fi
  if [ $# -eq 0 ]; then
    jq . "$CONFIG_FILE"
  else
    # Convert "section.key" to jq filter ".section.key // null"
    IFS='.' read -r -a parts <<< "$1"
    filter="."
    for part in "${parts[@]}"; do
      filter+=" | .\"$part\""
    done
    filter+=" // null"
    val=$(jq -r "$filter" "$CONFIG_FILE" 2>/dev/null || echo "null")
    if [ "$val" = "null" ]; then
      return 1
    fi
    printf '%s\n' "$val"
  fi
}

cmd_set() {
  if [ $# -lt 2 ]; then
    usage >&2
    return 1
  fi
  ensure_config_dir

  key="$1"
  shift
  raw_value="$*"

  # Convert dot-separated key to jq path JSON array
  IFS='.' read -r -a parts <<< "$key"
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
  fi > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

cmd_list() {
  if [ ! -f "$CONFIG_FILE" ]; then
    return 0
  fi
  jq -r '
    paths(scalars) as $p
    | { key: ($p | join(".")), val: getpath($p) | tojson }
    | "\(.key)=\(.val)"
  ' "$CONFIG_FILE"
}

case "${1:-}" in
  get) shift; cmd_get "$@" ;;
  set) shift; cmd_set "$@" ;;
  list) cmd_list ;;
  *) usage >&2; exit 1 ;;
esac
