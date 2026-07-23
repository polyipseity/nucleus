#!/usr/bin/env bash
# LiteLLM AI gateway daemon.
# Reads SOPS-decrypted API key files and starts litellm.
# Tokens below are substituted via Nix replaceStrings at build time.
# Positional args (for manual invocation):
#   $1 = config path (default: built-in via replaceStrings)
#   $2 = polling timeout in 5-second ticks (default: built-in via replaceStrings, 0 = no polling)
set -euo pipefail

config="${1:-__LITELLM_CONFIG__}"
poll_timeout="${2:-__LITELLM_POLL_TIMEOUT__}"
_poll_ticks="$poll_timeout"

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
  "__OPENROUTER_API_KEY_PATH__:OPENROUTER_API_KEY" \
  "__OPENCODE_GO_API_KEY_PATH__:OPENCODE_GO_API_KEY" \
  "__OPENCODE_ZEN_API_KEY_PATH__:OPENCODE_ZEN_API_KEY"; do
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
