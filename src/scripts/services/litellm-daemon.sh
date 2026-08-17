#!/usr/bin/env bash
# LiteLLM AI gateway daemon.
# Reads SOPS-decrypted API key files and starts litellm.
# All configuration values can be passed via env vars or CLI args:
#   LITELLM_CONFIG / $1 = config path
#   LITELLM_EVAL_TIMEOUT / $2 = polling timeout in 5-second ticks (0 = no polling)
#   LITELLM_OPENROUTER_API_KEY_PATH / $3 = OpenRouter API key file path
#   LITELLM_OPENGODE_GO_API_KEY_PATH / $4 = OpenCode Go API key file path
#   LITELLM_OPENGODE_ZEN_API_KEY_PATH / $5 = OpenCode Zen API key file path
#   LITELLM_COMMAND_CODE_API_KEY_PATH / $6 = Command Code API key file path
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

config="${LITELLM_CONFIG:-${1:?usage: litellm-daemon.sh <config> <poll_timeout> <openrouter_key_path> <opencode_go_key_path> <opencode_zen_key_path> <command_code_key_path>}}"
poll_timeout="${LITELLM_EVAL_TIMEOUT:-${2:?}}"
_poll_ticks="$poll_timeout"
_openrouter_key_path="${LITELLM_OPENROUTER_API_KEY_PATH:-${3:?}}"
_opencode_go_key_path="${LITELLM_OPENGODE_GO_API_KEY_PATH:-${4:?}}"
_opencode_zen_key_path="${LITELLM_OPENGODE_ZEN_API_KEY_PATH:-${5:?}}"
_command_code_key_path="${LITELLM_COMMAND_CODE_API_KEY_PATH:-${6:?}}"

# Poll for each key file when configured (macOS launchd needs to handle
# the boot-time race with sops-install-secrets; systemd on NixOS restarts
# quickly enough that polling is unnecessary).
_wait_for_keyfile() {
  _path="$1"
  _ticks="$2"
  while [ ! -f "$_path" ] && [ "$_ticks" -gt 0 ]; do
    warn "waiting for $_path ..."
    sleep 5
    _ticks=$((_ticks - 1))
  done
  if [ -f "$_path" ]; then
    cat "$_path"
    return 0
  else
    warn "WARNING $_path not found after $((_poll_ticks * 5))s, continuing without it"
    return 1
  fi
}

_read_keyfile() {
  _path="$1"
  if [ -f "$_path" ]; then
    cat "$_path"
    return 0
  fi
  return 1
}

for _spec in \
  "$_openrouter_key_path:OPENROUTER_API_KEY" \
  "$_opencode_go_key_path:OPENCODE_GO_API_KEY" \
  "$_opencode_zen_key_path:OPENCODE_ZEN_API_KEY" \
  "$_command_code_key_path:COMMAND_CODE_API_KEY"; do
  _keyfile="${_spec%%:*}"
  _varname="${_spec#*:}"
  if [ "$_poll_ticks" -gt 0 ]; then
    if _value="$(_wait_for_keyfile "$_keyfile" "$_poll_ticks")"; then
      export "$_varname"="$_value"
    fi
  else
    if _value="$(_read_keyfile "$_keyfile")"; then
      export "$_varname"="$_value"
    fi
  fi
done

exec litellm \
  --config "$config" \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
