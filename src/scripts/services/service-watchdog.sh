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
# See .agents/instructions/macos-launchd-sip.instructions.md.
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
  --domain <d>  Filter to only check services in this domain (user/system).
                When omitted, checks all services for the current host.
  --oneshot     Run once and exit (no persistent loop).
EOF
}

# Handle help request before any further processing.
watchdog_domain=""
watchdog_oneshot=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --domain)
      if [ -z "${2:-}" ]; then
        printf 'error: --domain requires an argument\n' >&2
        exit 1
      fi
      watchdog_domain="$2"
      shift
      ;;
    --oneshot)
      watchdog_oneshot=true
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
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
  MacBook|NixOS) ;;
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
  local svc="$1" domain="$2" svc_id="$3"
  local sudo_prefix=""
  if [ "$domain" = "system" ] && [ "$(id -u)" -ne 0 ]; then
    sudo_prefix="sudo"
  fi
  local target
  target=$(launchctl_target "$domain" "$svc_id")
  local plist=""
  if [ "$domain" = "system" ]; then
    plist="/Library/LaunchDaemons/$svc_id.plist"
  else
    plist="${HOME:-}/Library/LaunchAgents/$svc_id.plist"
  fi
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  $sudo_prefix launchctl bootout "$target" 2>/dev/null || true
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$domain")" "$plist" 2>/dev/null || true
}

check_service_macos() {
  local svc="$1" entry="$2"
  local domain svc_id
  domain=$(echo "$entry" | jq -r '.domain // "user"')
  svc_id=$(echo "$entry" | jq -r '.service // ""')
  [ -z "$svc_id" ] && return 0

  local sudo_prefix=""
  if [ "$domain" = "system" ] && [ "$(id -u)" -ne 0 ]; then
    sudo_prefix="sudo"
  fi
  local target
  target=$(launchctl_target "$domain" "$svc_id")
  local print_out
  # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
  print_out=$($sudo_prefix launchctl print "$target" 2>/dev/null || true)

  case "$print_out" in
    *"state = running"*)
      # Service is healthy — nothing to do.
      return 0
      ;;
    *"state = spawn scheduled"*)
      recover_launchctl "$svc" "$domain" "$svc_id"
      log_restart "$svc_id" "spawn scheduled"
      ;;
    *"state = waiting"*)
      recover_launchctl "$svc" "$domain" "$svc_id"
      log_restart "$svc_id" "waiting"
      ;;
    # Exit 78 (EX_CONFIG): non-retryable, launchd sets penalty box — needs bootout+bootstrap.
    # Exit 126 (transient): shell cannot exec; does NOT trigger penalty box.
    *"last exit code = 78"*)
      recover_launchctl "$svc" "$domain" "$svc_id"
      log_restart "$svc_id" "EX_CONFIG"
      ;;
    *"Service is not found"*|"")
      # Service not loaded — try bootstrapping.
      local plist=""
      if [ "$domain" = "system" ]; then
        plist="/Library/LaunchDaemons/$svc_id.plist"
      else
        plist="${HOME:-}/Library/LaunchAgents/$svc_id.plist"
      fi
      if [ -f "$plist" ]; then
        # check-suppress:suppression_doc: service may not be loaded or may fail transiently during recovery.
        $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$domain")" "$plist" 2>/dev/null || true
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
    active|activating|reloading)
      # Service is healthy — nothing to do.
      return 0
      ;;
    inactive|dead|failed|not-found|"")
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

    # If --domain was specified, skip services that don't match.
    if [ -n "$watchdog_domain" ]; then
      svc_domain=$(echo "$entry" | jq -r '.hostEntry.domain // "user"')
      if [ "$svc_domain" != "$watchdog_domain" ]; then
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
