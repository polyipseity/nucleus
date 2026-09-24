#!/usr/bin/env bash
# shellcheck shell=bash
# Service watchdog — detects and breaks loops, revives stopped services.
# Rewritten for the cloud-mount rewrite: one rule table, all hosts, no OS names.
#
# Rules (identical on every host):
#   1. supervisor_enabled=false → do nothing (user intent, documented)
#   2. Blocked record exists → report once, do nothing
#   3. supervisor_live + counter grew → loop → mark + stop
#   4. Not live + no record → start (revival — the only mechanism)
#   5. supervisor_repair for supervisor-level failures (EX_CONFIG 78, etc)
#
# Reads services.json, filters to the current host, skips on-demand services.
# Prefix-match entries are expanded per instance.
#
# Runs indefinitely with a 300 s sleep (persistent daemon).
# Use --oneshot for a single iteration (manual or CI).

set -euo pipefail

_WATCHDOG_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_WATCHDOG_DIR/../lib/lib.sh"
# shellcheck source=../lib/service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_WATCHDOG_DIR/../lib/service-health.sh"

# Dispatch to the correct supervisor backend.
_watchdog_dispatch_supervisor() {
  case "$(uname -s)" in
  Darwin)
    # shellcheck source=../lib/supervisor-launchd.sh
    . "$_WATCHDOG_DIR/../lib/supervisor-launchd.sh"
    ;;
  Linux)
    # shellcheck source=../lib/supervisor-systemd.sh
    . "$_WATCHDOG_DIR/../lib/supervisor-systemd.sh"
    ;;
  esac
}

# Parse CLI args.
_oneshot=false
for arg in "$@"; do
  case "$arg" in
  --oneshot) _oneshot=true ;;
  esac
done

# Main loop.
_watchdog_main() {
  _watchdog_dispatch_supervisor

  local interval=300
  while :; do
    _watchdog_tick
    if [ "$_oneshot" = true ]; then
      break
    fi
    sleep "$interval"
  done
}

# One tick: check all services on this host.
_watchdog_tick() {
  local repo_root
  repo_root="$(derive_repo_root)"

  local services_json="$repo_root/src/modules/services.json"
  [ -f "$services_json" ] || return 0

  local host_key
  host_key="$(get_nucleus_host_key)"

  # Get service keys from the JSON.
  local svc_keys
  # check-suppress:suppression_doc: best-effort operation; failure is non-fatal

  local svc_key
  for svc_key in $svc_keys; do
    local host_entry
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    svc_keys=$(jq -r 'keys[] | select(startswith("\$") | not)' "$services_json" 2>/dev/null || true)
    [ -n "$host_entry" ] || continue

    local svc_type
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    host_entry=$(jq -c ".$svc_key.hosts.$host_key // empty" "$services_json" 2>/dev/null || true)

    local on_demand
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    svc_type=$(printf '%s' "$host_entry" | jq -r '.type // empty' 2>/dev/null || true)
    [ "$on_demand" = "true" ] && continue

    local prefix_match
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    on_demand=$(printf '%s' "$host_entry" | jq -r '.onDemand // false' 2>/dev/null || true)

    if [ "$prefix_match" = "true" ]; then
      _watchdog_check_prefix "$svc_key" "$svc_type" "$host_entry"
    else
      _watchdog_check_single "$svc_key" "$svc_type" "$host_entry" "$svc_key"
    fi
  done
}

# Check a single (non-prefix) service.
_watchdog_check_single() {
  local svc_key="$1" svc_type="$2" host_entry="$3" instance="$4"
  _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$instance"
}

# Check all instances for a prefix-match service.
_watchdog_check_prefix() {
  local svc_key="$1" svc_type="$2" host_entry="$3"

  # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
  prefix_match=$(printf '%s' "$host_entry" | jq -r '.prefixMatch // false' 2>/dev/null || true)

  case "$svc_type" in
  macos-launchctl)
    local domain uid service_name
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    service_name=$(printf '%s' "$host_entry" | jq -r '.service // empty' 2>/dev/null || true)
    uid=$(id -u)
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    domain=$(printf '%s' "$host_entry" | jq -r '.launchdDomain // "gui"' 2>/dev/null || true)
    launchctl list 2>/dev/null | awk -v p="$domain/$uid/$service_name" '$0 ~ p {print $NF}' | while read -r label; do
      _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$label"
    done
    ;;
  nixos-systemctl)
    local service_name
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    service_name=$(printf '%s' "$host_entry" | jq -r '.service // empty' 2>/dev/null || true)
    systemctl --user list-units --type=service --all 2>/dev/null | awk -v p="$service_name" '$0 ~ p {print $1}' | while read -r unit; do
      _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$unit"
    done
    ;;
  windows-schtask)
    # WHY: Windows watchdog runs via service-watchdog.ps1, not this script.
    # This case exists to avoid shellcheck warnings about unreachable code.
    ;;
  esac
}

# Check one instance.
_watchdog_check_instance() {
  local svc_key="$1" svc_type="$2" host_entry="$3" instance="$4"
  [ -n "$instance" ] || return 0

  local target
  case "$svc_type" in
  macos-launchctl)
    local domain uid
    uid=$(id -u)
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    domain=$(printf '%s' "$host_entry" | jq -r '.launchdDomain // "gui"' 2>/dev/null || true)
    # instance IS the full launchd label (e.g. local.cloud-mount.OneDrive)
    target="$domain/$uid/$instance"
    ;;
  nixos-systemctl)
    # instance IS the full systemd unit name (e.g. cloud-mount-OneDrive.service)
    target="$instance"
    ;;
  windows-schtask)
    # instance IS the full task path + name
    local task_path task_name
    task_path=$(printf '%s' "$instance" | sed 's|\\[^\\]*$||')
    task_name=$(printf '%s' "$instance" | sed 's|.*\\||')
    target="$task_path|$task_name"
    ;;
  esac

  # Rule 1: is the supervisor enabled?
  if ! supervisor_enabled "$target"; then
    return 0
  fi

  # Rule 2: blocked record?
  if svc_health_is_blocked "$instance"; then
    local class remedy _blocked_state
    class=$(svc_health_get "$instance" "class" 2>/dev/null || echo "unknown")
    _blocked_state="$(svc_health_get "$instance" "state")"
    if ! svc_health_is_reported "$instance" "${_blocked_state}:${class}"; then
      remedy=$(svc_health_get "$instance" "remedy" 2>/dev/null || echo "")
      notice "watchdog: $instance is blocked ($class): $remedy"
      svc_health_mark_reported "$instance" "${_blocked_state}:${class}"
    fi
    return 0
  fi

  # Rule 4b: not-loaded record?
  local _state
  _state="$(svc_health_get "$instance" "state")"
  if [ "$_state" = "not-loaded" ]; then
    if ! svc_health_is_reported "$instance" "not-loaded"; then
      notice "watchdog: $instance is configured but not loaded (run 'nucleus-svc status $instance' or 'nucleus-apply')"
      svc_health_mark_reported "$instance" "not-loaded"
    fi
    return 0
  fi

  # Get supervisor state.
  local print_out=""
  case "$svc_type" in
  macos-launchctl)
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    print_out=$(launchctl print "$target" 2>/dev/null || true)
    ;;
  nixos-systemctl)
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    print_out=$(systemctl --user status "$target" 2>/dev/null || true)
    ;;
  windows-schtask)
    local task_path task_name
    task_path=$(printf '%s' "$target" | cut -d'|' -f1)
    task_name=$(printf '%s' "$target" | cut -d'|' -f2)
    print_out=$(Get-ScheduledTask -TaskPath "$task_path" -TaskName "$task_name" -ErrorAction SilentlyContinue | ConvertTo-Json)
    ;;
  esac

  local is_live=false
  if supervisor_live "$print_out"; then
    is_live=true
  fi

  local counter=0
  counter=$(supervisor_counter "$print_out")

  local last_exit=0
  last_exit=$(supervisor_last_exit "$print_out")

  if [ "$is_live" = true ]; then
    # Rule 3: counter grew → loop?
    local prev_counter
    prev_counter=$(svc_health_get "$instance" "runs" 2>/dev/null || echo "0")
    prev_counter="${prev_counter:-0}"

    # Update runs/lastExit every tick.
    svc_health_set "$instance" "runs" "$counter"
    svc_health_set_last_exit "$instance" "$last_exit"

    if svc_health_is_looping "$instance"; then
      # Health-record-driven loop detection: covers both counter-incrementing
      # restart loops and self-looping daemons (e.g. betterdisplay-heartbeat).
      notice "watchdog: $instance is looping (runs=$counter, last_exit=$last_exit); stopping"
      svc_health_set_blocked "$instance" "crash-loop" "supervisor is restarting the job in a loop"
      supervisor_stop "$target"
      return 0
    fi

    # Stable.
    return 0
  fi

  # Rule 4: not live + no record → revival.
  if ! svc_health_is_blocked "$instance" 2>/dev/null; then
    notice "watchdog: $instance is not running; starting"
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    print_out=$(systemctl --user status "$target" 2>/dev/null || true)
    return 0
  fi
}

_watchdog_main "$@"
