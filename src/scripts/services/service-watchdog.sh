#!/usr/bin/env bash
# Persistent-loop service watchdog — detects and restarts nucleus-managed
# services that are stuck in non-running states (EX_CONFIG, waiting,
# spawn-scheduled, inactive, failed, or not loaded at all), and reloads a
# KeepAlive job whose process exited cleanly (launchd never retries exit 0).
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
# Reads services.json, filters to the current host, skips socket-activated and
# on-demand services, and recovers each non-running service via
# bootout+bootstrap (launchctl) or reset-failed+restart (systemctl).
# Prefix-match entries are expanded per instance: each live instance is checked
# independently, and each instance the user registry declares but this host does
# not run is reported once per transition (never auto-loaded — see
# src/modules/cloud-drives.nix on the clean-exit-0 contract). A loaded instance
# that exited cleanly is a different case and is reloaded.
#
# An instance that wrote a blocked marker stopped on purpose, and is reported
# once per transition and never restarted (see service_blocked).

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
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  Persistent service watchdog — detects and restarts nucleus-managed
  services stuck in non-running states (EX_CONFIG, waiting,
  spawn-scheduled, clean exit, inactive, failed, or not loaded at all).
  Runs indefinitely with 300 s sleep between iterations.
  Use --oneshot for a single iteration (manual / CI use).
  An instance that wrote a blocked marker is reported once and never restarted.

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

# Cloud-drive mounts for this host, resolved lazily by watchdog_mounts.
# WHY: the loader needs a live repo root and aborts the tick when it fails, so
#   the resolution stays lazy (only prefix-match instances ask for it).
_watchdog_mounts=""
_watchdog_mounts_set=false

# Read services for this host, excluding socket-activated and on-demand services.
read_watchdog_services() {
  jq -c --arg host "$HOST" '
    to_entries[]
    | select(.value | type == "object")
    | select(.value.hosts | has($host))
    | select(.value.hosts[$host].type != "omitted")
    | select(.value.hosts[$host].socketActivated // false | not)
    | select(.value.hosts[$host].onDemand // false | not)
    | select(.key != "service-watchdog")
    | select(.key != "service-watchdog-user")
    | {key: .key, displayName: .value.displayName, hostEntry: .value.hosts[$host]}
  ' "$SERVICES_JSON"
}

log_restart() {
  local svc="$1" reason="$2"
  printf '[%s] watchdog: restarted %s (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$svc" "$reason"
}

# log_notloaded — Report an instance the registry declares but nothing runs.
# Args: $1 — registry key; $2 — instance id.
log_notloaded() {
  printf '[%s] watchdog: %s %s configured but not loaded (run '\''nucleus-svc status %s'\'' or '\''nucleus-apply'\'')\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$1"
}

# service_blocked — Report a deliberately blocked instance and leave it alone.
# Args: $1 — concrete instance id (also the marker key and the launchd label/
#       systemd unit the runtime records the block against).
# Returns: 0 when the instance is blocked, 1 when it is not.
# WHY: an instance that stopped on purpose is not broken — a cloud mount whose
#   macFUSE/FSKit provider refuses it writes a blocked marker and exits 0, so
#   KeepAlive{SuccessfulExit:false} does not resurrect it — and restarting it
#   here would re-enter the same failure on every 300s tick; each attempt also
#   re-registers the file-system extension, which deepens the wedge instead of
#   clearing it.  The marker is generic (any service may write one) and
#   boot-scoped, so it is reported once per transition and a block written before
#   a reboot never keeps an instance down afterwards.
# ref: https://github.com/macfuse/macfuse/issues/1132
service_blocked() {
  local svc_id="$1" state_dir blocked

  state_dir="$(crash_loop_state_dir)"
  blocked="$(svc_blocked_state "$svc_id" "$state_dir")"
  [ "$blocked" != "clear" ] || return 1
  if [ "$(svc_blocked_transition "$svc_id" "$state_dir" "$blocked")" = first ]; then
    printf '[%s] watchdog: %s is blocked (%s); %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$svc_id" "${blocked#blocked }" \
      "$(svc_blocked_remedy "$svc_id" "$state_dir")"
  fi
  return 0
}

# watchdog_mounts — Memoized cloud-drive mounts the invoking user declares.
# Output: the mounts array JSON.
# WHY: every cloud-mount instance needs its mount point, and each lookup runs
#   the user-registry loader; memoizing keeps one loader invocation per tick.
watchdog_mounts() {
  if [ "$_watchdog_mounts_set" != true ]; then
    _watchdog_mounts="$(svc_configured_mounts "$(derive_repo_root)" "$HOST")"
    _watchdog_mounts_set=true
  fi
  printf '%s\n' "$_watchdog_mounts"
}

# check_service_instances — Monitor every instance of a prefix-match entry.
# Args: $1 — registry key; $2 — host entry JSON.
# WHY: a prefix-match entry stands in for one runtime service per configured
# instance, so each instance is checked and tracked separately; a declared but
# absent instance is reported once per transition instead of being restarted,
# because those units exit 0 by design when their remote is unconfigured.
check_service_instances() {
  local key="$1" entry="$2"
  local instances configured instance instance_entry

  instances=$(svc_prefix_instances "$entry")

  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    instance_entry=$(svc_instance_entry "$entry" "$instance")
    case "$HOST" in
    MacBook) check_service_macos "$instance" "$instance_entry" "$entry" ;;
    NixOS) check_service_nixos "$instance" "$instance_entry" ;;
    esac
    svc_notloaded_clear "$instance" "$(crash_loop_state_dir)"
  done <<<"$instances"

  configured=$(svc_configured_instance_ids "$entry" "$(svc_configured_mounts "$(derive_repo_root)" "$HOST")")
  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    if svc_list_contains "$instances" "$instance"; then continue; fi
    if [ "$(svc_notloaded_transition "$instance" "$(crash_loop_state_dir)")" != first ]; then continue; fi
    log_notloaded "$key" "$instance"
  done <<<"$configured"
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
  # WHY: see launchctl_bootout_wait — macOS 26+ unloads asynchronously, so a
  #   bootstrap issued before the unload completes fails with "Bootstrap failed:
  #   5:" and the service stays unloaded.
  if ! launchctl_bootout_wait "$target" "$sudo_prefix"; then
    error "watchdog: $svc_id — launchctl bootout did not unload $target"
    return 1
  fi
  local out="" bootstrap_domain=""
  bootstrap_domain="$(launchctl_bootstrap_domain "$launchd_domain" "$uid")"
  if out=$(launchctl_bootstrap_plist "$bootstrap_domain" "$plist" "$target" "$sudo_prefix"); then
    return 0
  fi
  error "watchdog: $svc_id — launchctl bootstrap failed: $out"
  return 1
}

# service_declares_clean_exit_restart — Whether a plist opts into
# KeepAlive{SuccessfulExit:false}.
# Args: $1 — plist path.
# Returns 0 when the plist declares both KeepAlive and SuccessfulExit, 1
# otherwise (including when the plist is missing or unreadable).
# WHY: that is the only contract under which launchd leaves a cleanly exited job
#   stopped, so it is the only one this watchdog may reload. A periodic agent
#   that finished its work, and a KeepAlive=true job (which launchd restarts by
#   itself), must be left alone.
service_declares_clean_exit_restart() {
  local plist="$1" dumped=""

  [ -f "$plist" ] || return 1
  # check-suppress:suppression_doc: a plist that cannot be dumped is not a clean-exit KeepAlive job, which is the answer this probe reports.
  dumped="$(svc_run_bounded 5 plutil -p "$plist" 2>/dev/null)" || true
  case "$dumped" in
  *KeepAlive*) ;;
  *) return 1 ;;
  esac
  case "$dumped" in
  *SuccessfulExit*) return 0 ;;
  *) return 1 ;;
  esac
}

# check_service_macos — Check one macOS service and recover it when stuck.
# Args: $1 — service name (crash-loop key); $2 — service entry JSON;
#       $3 — prefix-match host entry JSON ("" for an ordinary service).
check_service_macos() {
  local svc="$1" entry="$2" prefix_entry="${3:-}"
  local scope launchd_domain svc_id uid
  scope=$(echo "$entry" | jq -r '.scope // "user"')
  launchd_domain=$(echo "$entry" | jq -r '.launchdDomain // "gui"')
  svc_id=$(echo "$entry" | jq -r '.service // ""')
  uid="${REAL_USER_UID:-$(id -u)}"
  [ -z "$svc_id" ] && return 0

  # WHY: checked before every probe and before any recovery, so a blocked
  #   instance is neither reloaded nor even inspected further.
  if service_blocked "$svc_id"; then
    return 0
  fi

  local plist=""
  if [ "$scope" = "system" ]; then
    plist="/Library/LaunchDaemons/$svc_id.plist"
  else
    plist="${HOME:-}/Library/LaunchAgents/$svc_id.plist"
  fi

  local mount_point=""
  if [ -n "$prefix_entry" ]; then
    mount_point="$(svc_cloud_mount_point "$prefix_entry" "$(watchdog_mounts)" "$svc_id")"
  fi

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
      warn "watchdog: $svc_id is crash-looping — skipping restart"
      return 0
    fi
    crash_loop_record "$svc" "spawn-scheduled"
    # check-suppress:suppression_doc: recover_launchctl already reported the failure via error; the watchdog keeps watching the remaining services.
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid" || true
    log_restart "$svc_id" "spawn scheduled"
    ;;
  *"state = waiting"*)
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: $svc_id is crash-looping — skipping restart"
      return 0
    fi
    crash_loop_record "$svc" "waiting"
    # check-suppress:suppression_doc: recover_launchctl already reported the failure via error; the watchdog keeps watching the remaining services.
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid" || true
    log_restart "$svc_id" "waiting"
    ;;
  # Exit 78 (EX_CONFIG): non-retryable, launchd sets penalty box — needs bootout+bootstrap.
  # Exit 126 (transient): shell cannot exec; does NOT trigger penalty box.
  *"last exit code = 78"*)
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: $svc_id is crash-looping — skipping restart"
      return 0
    fi
    crash_loop_record "$svc" "EX_CONFIG"
    # check-suppress:suppression_doc: recover_launchctl already reported the failure via error; the watchdog keeps watching the remaining services.
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid" || true
    log_restart "$svc_id" "EX_CONFIG"
    ;;
  # A loaded job that is not running and exited cleanly: launchd does not retry a
  # status of 0 under KeepAlive{SuccessfulExit:false}, so nothing brings the
  # service back on its own.
  *"last exit code = 0"*)
    if ! service_declares_clean_exit_restart "$plist"; then
      return 0
    fi
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: $svc_id is crash-looping — skipping restart"
      return 0
    fi
    if [ -n "$mount_point" ] && ! svc_wait_mount_released "$mount_point"; then
      # check-suppress:suppression_doc: error's status is consumed because the watchdog must keep watching the remaining services.
      error "watchdog: $svc_id — mount point $mount_point is still mounted; not reloading the agent over a stale volume" || true
      return 0
    fi
    crash_loop_record "$svc" "clean exit"
    # check-suppress:suppression_doc: recover_launchctl already reported the failure via error; the watchdog keeps watching the remaining services.
    recover_launchctl "$svc" "$scope" "$launchd_domain" "$svc_id" "$uid" || true
    log_restart "$svc_id" "clean exit"
    ;;
  *"Service is not found"* | "")
    # Service not loaded — try bootstrapping.
    if crash_loop_is_looping "$svc"; then
      warn "watchdog: $svc_id is crash-looping — skipping restart"
      return 0
    fi
    if [ -f "$plist" ]; then
      crash_loop_record "$svc" "not-found"
      local bootstrap_out="" bootstrap_domain=""
      bootstrap_domain="$(launchctl_bootstrap_domain "$launchd_domain" "$uid")"
      if bootstrap_out=$(launchctl_bootstrap_plist "$bootstrap_domain" "$plist" "$target" "$sudo_prefix"); then
        log_restart "$svc_id" "not found — bootstrap"
      else
        # check-suppress:suppression_doc: error's status is consumed because the watchdog must keep watching the remaining services.
        error "watchdog: $svc_id — launchctl bootstrap failed: $bootstrap_out" || true
      fi
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

  # WHY: the marker facility is generic, so a NixOS unit that wrote one is left
  #   alone here as well; nothing about the block is macOS-specific.
  if service_blocked "$svc_id"; then
    return 0
  fi
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
      warn "watchdog: $svc_id is crash-looping — skipping restart"
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
    entry_json=$(echo "$entry" | jq -c '.hostEntry')

    # If --scope was specified, skip services that don't match.
    if [ -n "$watchdog_scope" ]; then
      svc_scope=$(echo "$entry_json" | jq -r '.scope // "user"')
      if [ "$svc_scope" != "$watchdog_scope" ]; then
        continue
      fi
    fi

    if [ "$(printf '%s' "$entry_json" | jq -r '.prefixMatch // false')" = "true" ]; then
      check_service_instances "$key" "$entry_json"
      continue
    fi

    case "$HOST" in
    MacBook) check_service_macos "$key" "$entry_json" "" ;;
    NixOS) check_service_nixos "$key" "$entry_json" ;;
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
