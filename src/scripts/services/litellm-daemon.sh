#!/usr/bin/env bash
# LiteLLM AI gateway daemon.
# Reads SOPS-decrypted API key files and starts litellm.
#
# Usage: litellm-daemon.sh <config> <poll_timeout> [KEYFILE:ENVVAR ...]
#
#   config          Path to litellm-config.yml
#   poll_timeout    Polling timeout in 5-second ticks (0 = no polling)
#   KEYFILE:ENVVAR  Pairs of key file path and env var name to export.
#                   Zero or more pairs — zero means no remote keys.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

config="${LITELLM_CONFIG:-${1:?usage: litellm-daemon.sh <config> <poll_timeout> [KEYFILE:ENVVAR ...]}}"
poll_timeout="${LITELLM_EVAL_TIMEOUT:-${2:?}}"
_poll_ticks="$poll_timeout"
shift 2 || true # check-suppress:suppression_doc: shift fails when config and poll_timeout are supplied via env vars (no positional args)

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

for _spec in "$@"; do
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

# Opt-in Redis readiness gate. launchd has no native ordering primitive, so
# when LITELLM_REDIS_POLL_TICKS is set we wait for the local Redis server to
# accept a TCP connection before starting litellm. This covers the boot-time
# race between local.redis and local.litellm on macOS (systemd on NixOS orders
# via After=/Wants= instead). The gate is a no-op when the var is unset.
_redis_ticks="${LITELLM_REDIS_POLL_TICKS:-0}"
if [ "${_redis_ticks}" -gt 0 ]; then
  _redis_host="${LITELLM_REDIS_HOST:-127.0.0.1}"
  _redis_port="${LITELLM_REDIS_PORT:-6379}"
  _redis_up=0
  while [ "$_redis_ticks" -gt 0 ] && [ "$_redis_up" -eq 0 ]; do
    if (exec 3<>"/dev/tcp/${_redis_host}/${_redis_port}") 2>/dev/null; then
      _redis_up=1
      exec 3>&- 3<&-
    else
      warn "waiting for Redis at ${_redis_host}:${_redis_port} ..."
      sleep 5
      _redis_ticks=$((_redis_ticks - 1))
    fi
  done
  if [ "$_redis_up" -eq 0 ]; then
    warn "WARNING Redis not reachable at ${_redis_host}:${_redis_port} after timeout, starting litellm anyway (it will reconnect)"
  fi
fi

exec litellm \
  --config "$config" \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
