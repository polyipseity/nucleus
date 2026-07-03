#!/usr/bin/env bash
# Periodic service watchdog — detects and restarts nucleus-managed services
# that are stuck in non-running states (EX_CONFIG, waiting, spawn-scheduled,
# inactive, failed, or not loaded at all).
#
# Reads services.json, filters to the current platform, skips socket-activated
# and prefix-match services, and recovers each non-running service via
# bootout+bootstrap (launchctl) or reset-failed+restart (systemctl).
#
# Intended to run every 5 minutes from:
#   - macOS: launchd agent with StartInterval=300
#   - NixOS: systemd timer with OnUnitActiveSec=5min
#   - Windows: scheduled task with PT5M repetition (via .ps1 counterpart)

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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT="$(derive_repo_root)"

# Handle help request before any further processing.
for _arg in "$@"; do
  case "$_arg" in
    -h|--help)
      usage_std "$(basename "$0")" "[options]"
      cat <<'EOF'
  Periodic service watchdog — detects and restarts nucleus-managed
  services stuck in non-running states (EX_CONFIG, waiting,
  spawn-scheduled, inactive, failed, or not loaded at all).
  Intended to run from a periodic timer (launchd/systemd/schtask).

  Options:
  -h|--help  Show usage.
EOF
      exit 0
      ;;
  esac
done

SERVICES_JSON="$REPO_ROOT/src/modules/services.json"
HOST="$(resolve_nucleus_host)"

case "$HOST" in
  MacBook) PLATFORM="macos" ;;
  NixOS)   PLATFORM="nixos" ;;
  *)
    # Windows watchdog is handled by service-watchdog.ps1; exit silently.
    exit 0
    ;;
esac

require_command jq

# Read services for this platform, excluding socket-activated and prefix-match.
read_watchdog_services() {
  jq -c --arg platform "$PLATFORM" '
    to_entries[]
    | select(.value | type == "object")
    | select(.value.platforms | has($platform))
    | select(.value.platforms[$platform].type != "omitted")
    | select(.value.platforms[$platform].socketActivated // false | not)
    | select(.value.platforms[$platform].prefixMatch // false | not)
    | {key: .key, displayName: .value.displayName, platform: .value.platforms[$platform]}
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
    plist="$HOME/Library/LaunchAgents/$svc_id.plist"
  fi
  $sudo_prefix launchctl bootout "$target" 2>/dev/null || true
  $sudo_prefix launchctl bootstrap "$domain" "$plist" 2>/dev/null || true
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
        plist="$HOME/Library/LaunchAgents/$svc_id.plist"
      fi
      if [ -f "$plist" ]; then
        $sudo_prefix launchctl bootstrap "$domain" "$plist" 2>/dev/null || true
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
  is_active=$(systemctl $scope_flag is-active "$svc_id" 2>/dev/null || true)

  case "$is_active" in
    active|activating|reloading)
      # Service is healthy — nothing to do.
      return 0
      ;;
    inactive|dead|failed|not-found|"")
      # Stuck or missing — reset limits and restart.
      systemctl $scope_flag reset-failed "$svc_id" 2>/dev/null || true
      systemctl $scope_flag restart "$svc_id" 2>/dev/null || true
      log_restart "$svc_id" "state=$is_active"
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  key=$(echo "$entry" | jq -r '.key')

  case "$PLATFORM" in
    macos) check_service_macos "$key" "$(echo "$entry" | jq -c '.platform')" ;;
    nixos) check_service_nixos "$key" "$(echo "$entry" | jq -c '.platform')" ;;
  esac
done < <(read_watchdog_services)
