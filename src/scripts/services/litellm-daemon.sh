#!/usr/bin/env bash
# Starts the LiteLLM gateway with SOPS-decrypted API key files.
#
# Usage: litellm-daemon.sh <config> <poll_timeout> [KEYFILE:ENVVAR ...]
#   config          Path to litellm-config.yml
#   poll_timeout    Polling timeout in 5-second ticks (0 = no polling)
#   KEYFILE:ENVVAR  Key file path and env var name to export, paired. Zero pairs is valid.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

config="${LITELLM_CONFIG:-${1:?usage: litellm-daemon.sh <config> <poll_timeout> [KEYFILE:ENVVAR ...]}}"
poll_timeout="${LITELLM_EVAL_TIMEOUT:-${2:?}}"
_poll_ticks="$poll_timeout"
shift 2 || true # check-suppress:suppression_doc: shift fails when config and poll_timeout are supplied via env vars (no positional args)

# WHY: poll each key file when configured. macOS launchd needs this to handle the boot-time
# race with sops-install-secrets; systemd on NixOS restarts fast enough without it.
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

# Opt-in Redis readiness gate, covering the macOS boot-time race between local.redis and
# local.litellm; systemd orders via After=/Wants= instead. launchd has no ordering primitive,
# so LITELLM_REDIS_POLL_TICKS waits for a TCP connect. No-op when unset.
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

# The logging config comes from the user-scope seeder (home.activation.seed-litellm-config)
# and this daemon starts at boot, so wait for it as the Redis block above does.
_log_config_deadline="${LITELLM_LOG_CONFIG_WAIT_SECONDS:-60}"
if [ -n "${LITELLM_LOG_CONFIG:-}" ] && [ ! -f "$LITELLM_LOG_CONFIG" ]; then
  warn "waiting for the litellm logging config at $LITELLM_LOG_CONFIG ..."
  _log_config_ticks="$_log_config_deadline"
  while [ "$_log_config_ticks" -gt 0 ] && [ ! -f "$LITELLM_LOG_CONFIG" ]; do
    sleep 5
    _log_config_ticks=$((_log_config_ticks - 5))
  done
fi

# WHY: the flag is a quoted argument in each branch rather than an assembled string. The
# macOS path has a space ("Library/Application Support/nucleus/..."), and an unquoted
# expansion splits it into a truncated value plus a stray positional argument.
if [ -n "${LITELLM_LOG_CONFIG:-}" ]; then
  if [ ! -f "$LITELLM_LOG_CONFIG" ]; then
    die -l litellm-daemon "LITELLM_LOG_CONFIG=$LITELLM_LOG_CONFIG does not exist after ${_log_config_deadline}s; home.activation.seed-litellm-config did not converge"
  fi
  exec litellm \
    --config "$config" \
    --port 4000 \
    --host 127.0.0.1 \
    --drop_params \
    --log_config "$LITELLM_LOG_CONFIG"
fi

exec litellm \
  --config "$config" \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
