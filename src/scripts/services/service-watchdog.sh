#!/usr/bin/env bash
# Persistent-loop service watchdog — detects and restarts nucleus-managed
# services that are stuck in non-running states (EX_CONFIG, waiting,
# spawn-scheduled, inactive, failed, or not loaded at all).
#
# Runs indefinitely with a 300 s sleep between iterations (persistent daemon
# pattern — launched by KeepAlive / Restart=always / scheduled task AtStartup).
# Use --oneshot to run a single iteration (for manual or CI use).
#
# On macOS 26+, SIP blocks unsigned Nix store binaries for system daemons
# with non-root UserName (exit 78 / EX_CONFIG). All MacBook daemons use
# /bin/sh wrapper; this watchdog recovers any that get stuck at boot.
# See .agents/instructions/macos-service-hardening.instructions.md.
#
# Reads services.json, filters to the current host, skips socket-activated
# and prefix-match services, and recovers each non-running service via
# bootout+bootstrap (launchctl) or reset-failed+restart (systemctl).

set -euo pipefail

# Log unexpected exit codes to stderr for diagnostics.
_trap_exit() {
  local _exit_code=$?
  if [ "$_exit_code" -ne 0 ]; then
    printf '[%s] watchdog: unexpected exit code %d\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_exit_code" >&2
  fi
}
trap _trap_exit EXIT

_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/macos-launch-services.sh
. "$SCRIPT_DIR/../lib/macos-launch-services.sh"
# shellcheck source=../lib/crash-loop.sh
. "$SCRIPT_DIR/../lib/crash-loop.sh"

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  Persistent service watchdog — detects and restarts nucleus-managed
  services stuck in non-running states (EX_CONFIG, waiting,
  spawn-scheduled, inactive, failed, or not loaded at all).
  Runs indefinitely with 300 s sleep between iterations.
  Use --oneshot for a single iteration (manual / CI use).

  Options:
  -h|--help     Show usage.
  --scope <s>  Filter to only check services in this scope (user/system).
                When omitted, checks all services for the current host.
  --oneshot     Run once and exit (no persistent loop).
EOF
}

# Handle help request before any further processing.
watchdog_scope=""
watchdog_oneshot=false
while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --scope)
    if [ -z "${2:-}" ]; then
      error "--scope requires an argument"
      exit 1
    fi
    watchdog_scope="$2"
    shift
    ;;
  --oneshot)
    watchdog_oneshot=true
    ;;
  *)
    error "unknown option: $1"
    exit 1
    ;;
  esac
  shift
done

SERVICES_JSON="${NUCLEUS_SERVICES_JSON:-}"
if [ -z "$SERVICES_JSON" ]; then
  REPO_ROOT="$(derive_repo_root)"
  SERVICES_JSON="${REPO_ROOT}/src/modules/services.json"
fi
HOST="$(resolve_nucleus_host)"

case "$HOST" in
MacBook | NixOS) ;;
*)
  # Windows watchdog is handled by service-watchdog.ps1; exit silently.
  exit 0
  ;;
esac

require_command jq

# Read services for this host, excluding socket-activated and prefix-match.
read_watchdog_services() {
  jq -c --arg host "$HOST" '
    to_entries[]
    | select(.value | type == "object")
    | select(.value.hosts | has($host))
    | select(.value.hosts[$host].type != "omitted")
    | select(.value.hosts[$host].socketActivated // false | not)
    | select(.value.hosts[$host].prefixMatch // false | not)
    | select(.value.hosts[$host].onDemand // false | not)
    | select(.key != "service-watchdog")
    | {key: .key, displayName: .value.displayName, hostEntry: .value.hosts[$host]}
  ' "$SERVICES_JSON"
}

log_restart() {
  local svc="$1" reason="$2"
  printf '[%s] watchdog: restarted %s (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$svc" "$reason"
}

# ──────────────────────────────────────────────────────────────────────────────
# macOS (launchctl)
# ──────────────────────────────────────────────────────────────────────────────
recover_launchctl() {
  local svc="$1" scope="$2" launchd_domain="$3" svc_id="$4" uid="$5"
  local sudo_prefix=""
  if [ "$scope" = "system" ] && [ "$(id -u)" -ne 0 ]; then
    sudo_prefix="sudo"
  fi
  local target
  target=$(launchctl_target "$launchd_domain" "$uid" "$svc_id")
  local plist=""
  if [ "$scope" = "system" ]; then
    plist="/Library/LaunchDaemons/$svc_id.plist"
  else
    plist="${HOME:-}/Library/LaunchAgents/$svc_id.plist"
  fi
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  $sudo_prefix launchctl bootout "$target" 2>/dev/null || true
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$launchd_domain" "$uid")" "$plist" 2>/dev/null || true
}

check_service_macos() {
  local svc="$1" entry="$2"
  local scope launchd_domain svc_id uid
  scope=$(echo "$entry" | jq -r '.scope // "user"')
  launchd_domain=$(echo "$entry" | jq -r '.launchdDomain // "gui"')
  svc_id=$(echo "$entry" | jq -r '.service // ""')
  uid="${REAL_USER_UID:-$(id -u)}"
  [ -z "$svc_id" ] && return 0

  local sudo_prefix=""
  if [ "$scope" = "system" ] && [ "$(id -u)" -ne 0 ]; then
    sudo_prefix="sudo"
  fi
  local target
  target=$(launchctl_target "$launchd_domain" "$uid" "$svc_id")
  local print_out
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  print_out=$($sudo_prefix launchctl print "$target" 2>/dev/null || true)

  case "$print_out" in
  *"state = running"*)
    # Service is healthy — record success for crash-loop detection.
    crash_loop_success "$svc"
    return 0
    ;;
  *"state = spawn scheduled"*)
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: %s is crash-looping — skipping restart" "$svc_id"
      return 0
    fi
    crash_loop_record "$svc" "spawn-scheduled"
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid"
    log_restart "$svc_id" "spawn scheduled"
    ;;
  *"state = waiting"*)
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: %s is crash-looping — skipping restart" "$svc_id"
      return 0
    fi
    crash_loop_record "$svc" "waiting"
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid"
    log_restart "$svc_id" "waiting"
    ;;
  # Exit 78 (EX_CONFIG): non-retryable, launchd sets penalty box — needs bootout+bootstrap.
  # Exit 126 (transient): shell cannot exec; does NOT trigger penalty box.
  *"last exit code = 78"*)
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: %s is crash-looping — skipping restart" "$svc_id"
      return 0
    fi
    crash_loop_record "$svc" "EX_CONFIG"
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid"
    log_restart "$svc_id" "EX_CONFIG"
    ;;
  *"Service is not found"* | "")
    # Service not loaded — try bootstrapping.
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: %s is crash-looping — skipping restart" "$svc_id"
      return 0
    fi
    local plist=""
    if [ "$scope" = "system" ]; then
      plist="/Library/LaunchDaemons/$svc_id.plist"
    else
      plist="${HOME:-}/Library/LaunchAgents/$svc_id.plist"
    fi
    if [ -f "$plist" ]; then
      crash_loop_record "$svc" "not-found"
      # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
      $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$launchd_domain" "$uid")" "$plist" 2>/dev/null || true
      log_restart "$svc_id" "not found — bootstrap"
    fi
    ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# NixOS (systemctl)
# ──────────────────────────────────────────────────────────────────────────────
check_service_nixos() {
  local svc="$1" entry="$2"
  local scope svc_id scope_flag=""
  scope=$(echo "$entry" | jq -r '.scope // "system"')
  svc_id=$(echo "$entry" | jq -r '.service // ""')
  [ -z "$svc_id" ] && return 0
  [ "$scope" = "user" ] && scope_flag="--user"

  local is_active
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  is_active=$(systemctl $scope_flag is-active "$svc_id" 2>/dev/null || true)

  case "$is_active" in
  active | activating | reloading)
    # Service is healthy — record success for crash-loop detection.
    crash_loop_success "$svc"
    return 0
    ;;
  inactive | dead | failed | not-found | "")
    # Check crash-loop before restarting.
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: %s is crash-looping — skipping restart" "$svc_id"
      return 0
    fi
    crash_loop_record "$svc" "state=$is_active"
    # Stuck or missing — reset limits and restart.
    # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
    systemctl $scope_flag reset-failed "$svc_id" 2>/dev/null || true
    # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
    systemctl $scope_flag restart "$svc_id" 2>/dev/null || true
    log_restart "$svc_id" "state=$is_active"
    ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Main loop (persistent daemon pattern)
# ──────────────────────────────────────────────────────────────────────────────
_run_watchdog_iteration() {
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    key=$(echo "$entry" | jq -r '.key')

    # If --scope was specified, skip services that don't match.
    if [ -n "$watchdog_scope" ]; then
      svc_scope=$(echo "$entry" | jq -r '.hostEntry.scope // "user"')
      if [ "$svc_scope" != "$watchdog_scope" ]; then
        continue
      fi
    fi

    case "$HOST" in
    MacBook) check_service_macos "$key" "$(echo "$entry" | jq -c '.hostEntry')" ;;
    NixOS) check_service_nixos "$key" "$(echo "$entry" | jq -c '.hostEntry')" ;;
    esac
  done < <(read_watchdog_services)
}

if [ "$watchdog_oneshot" = true ]; then
  _run_watchdog_iteration
else
  while true; do
    _run_watchdog_iteration
    sleep 300
  done
fi
