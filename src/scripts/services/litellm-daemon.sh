#!/usr/bin/env bash
# LiteLLM AI gateway daemon.
# Reads SOPS-decrypted API key files and starts litellm.
# All configuration values are passed as positional CLI args:
#   $1 = config path
#   $2 = polling timeout in 5-second ticks (0 = no polling)
#   $3 = OpenRouter API key file path
#   $4 = OpenCode Go API key file path
#   $5 = OpenCode Zen API key file path
set -euo pipefail

config="${1:?usage: litellm-daemon.sh <config> <poll_timeout> <openrouter_key_path> <opencode_go_key_path> <opencode_zen_key_path>}"
poll_timeout="${2:?}"
_poll_ticks="$poll_timeout"
_openrouter_key_path="${3:?}"
_opencode_go_key_path="${4:?}"
_opencode_zen_key_path="${5:?}"

# Poll for each key file when configured (macOS launchd needs to handle
# the boot-time race with sops-install-secrets; systemd on NixOS restarts
# quickly enough that polling is unnecessary).
_wait_for_keyfile() {
  _path="$1"
  _ticks="$2"
  while [ ! -f "$_path" ] && [ "$_ticks" -gt 0 ]; do
    echo "litellm-daemon: waiting for $_path ..." >&2
    sleep 5
    _ticks=$((_ticks - 1))
  done
  if [ -f "$_path" ]; then
    cat "$_path"
    return 0
  else
    echo "litellm-daemon: WARNING $_path not found after $((_poll_ticks * 5))s, continuing without it" >&2
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
  "$_opencode_zen_key_path:OPENCODE_ZEN_API_KEY"; do
  _keyfile="${_spec%%:*}"
  _varname="${_spec#*:}"
  if [ "$_poll_ticks" -gt 0 ]; then
    if _value="$(_wait_for_keyfile "$_keyfile" "$_poll_ticks")"; then
      export "$_varname"="$(_value)"
    fi
  else
    if _value="$(_read_keyfile "$_keyfile")"; then
      export "$_varname"="$(_value)"
    fi
  fi
done

exec litellm \
  --config "$config" \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
