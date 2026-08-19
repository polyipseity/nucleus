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

exec litellm \
  --config "$config" \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
