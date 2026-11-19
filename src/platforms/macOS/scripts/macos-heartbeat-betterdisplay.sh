#!/usr/bin/env bash
# BetterDisplay virtual screen heartbeat.
#
# Environment variables:
#   BD_BIN, BD_DISPLAY_NAME (DISPLAY_NAME accepted for compatibility)
#   BD_INTERVAL, BD_HEARTBEAT_ONCE (test hooks)

set -uo pipefail

_BD_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/service-health.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/service-health.sh"

if [ -z "${BD_DISPLAY_NAME+x}" ] && [ -n "${DISPLAY_NAME+x}" ]; then
  export BD_DISPLAY_NAME="$DISPLAY_NAME"
fi
# shellcheck source=../../../scripts/lib/betterdisplay.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/betterdisplay.sh"

BD_INTERVAL="${BD_INTERVAL:-60}"
BD_HEARTBEAT_ONCE="${BD_HEARTBEAT_ONCE:-}"

if ! bd_app_running; then
  exit 1
fi

_bd_last_anomaly=""
_bd_healthy_prev=0

while true; do
  if ! bd_app_running; then
    exit 1
  fi
  bd_probe
  case "$BD_PROBE_STATE" in
  healthy)
    if [ "$_bd_healthy_prev" -eq 0 ]; then
      svc_health_record_success "betterdisplay-heartbeat"
    fi
    _bd_healthy_prev=1
    _bd_last_anomaly=""
    ;;
  anomaly)
    if [ "$BD_PROBE_OBSERVED" != "$_bd_last_anomaly" ]; then
      printf 'headless display probe returned unexpected state: %s\n' "$BD_PROBE_OBSERVED" >&2
      _bd_last_anomaly="$BD_PROBE_OBSERVED"
    fi
    _bd_healthy_prev=0
    ;;
  missing)
    if bd_converge; then
      svc_health_record_success "betterdisplay-heartbeat"
      _bd_healthy_prev=1
      _bd_last_anomaly=""
    else
      exit 1
    fi
    ;;
  esac

  sleep "$BD_INTERVAL"
  if [ "$BD_HEARTBEAT_ONCE" = "1" ]; then
    exit 0
  fi
done
