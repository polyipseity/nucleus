#!/usr/bin/env bash
# BetterDisplay virtual screen heartbeat: reconciles the HeadlessDisplay on a
# fixed cadence and records service health. Restart tracking and loop detection
# come from svc_health and the watchdog.
#
# Environment variables (with built-in defaults, via betterdisplay lib):
#   BD_BIN, BD_APP, BD_DISPLAY_NAME (DISPLAY_NAME accepted for compatibility)

set +e # heartbeat is fully soft-fail; never abort on individual check failure

_BD_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/service-health.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/service-health.sh"
# shellcheck source=../../../scripts/lib/svc-instances.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/svc-instances.sh"

if [ -z "${BD_DISPLAY_NAME+x}" ] && [ -n "${DISPLAY_NAME+x}" ]; then
  export BD_DISPLAY_NAME="$DISPLAY_NAME"
fi
# shellcheck source=../../../scripts/lib/betterdisplay.sh
. "$_BD_SCRIPT_DIR/../../../scripts/lib/betterdisplay.sh"

_bd_healthy_prev=0
_bd_fail_streak=0
_bd_backoff=60
_bd_backoff_max=300

while true; do
  if [ ! -f "$BD_BIN" ]; then
    _bd_healthy_prev=0
    _bd_fail_streak=0
    _bd_backoff=60
    sleep 60
    continue
  fi

  # check-suppress:suppression_doc: bd_reconcile may fail for an unresponsive app or transient CLI error; the loop records the failure, backs off, and continues.
  bd_reconcile || true
  case "${BD_RECONCILE_STATUS-}" in
  converged)
    if [ "$_bd_healthy_prev" -ne 1 ]; then
      svc_health_record_success "betterdisplay-heartbeat"
    fi
    _bd_healthy_prev=1
    _bd_fail_streak=0
    _bd_backoff=60
    sleep 60
    ;;
  recreated)
    svc_health_record_restart "betterdisplay-heartbeat" "recreated"
    svc_health_record_success "betterdisplay-heartbeat"
    _bd_healthy_prev=1
    _bd_fail_streak=0
    _bd_backoff=60
    sleep 60
    ;;
  absent)
    _bd_healthy_prev=0
    _bd_fail_streak=0
    _bd_backoff=60
    sleep 60
    ;;
  *)
    svc_health_record_restart "betterdisplay-heartbeat" "reconcile-failed"
    _bd_healthy_prev=0
    _bd_fail_streak=$((_bd_fail_streak + 1))
    if [ "$_bd_fail_streak" -le 1 ]; then
      _bd_backoff=120
    else
      _bd_backoff=$((_bd_backoff * 2))
    fi
    if [ "$_bd_backoff" -gt "$_bd_backoff_max" ]; then
      _bd_backoff=$_bd_backoff_max
    fi
    sleep "$_bd_backoff"
    ;;
  esac
done
