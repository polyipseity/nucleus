#!/usr/bin/env bash
# shellcheck shell=bash
# Service watchdog: detects and breaks loops, revives stopped services. One rule
# table, all hosts, no OS names. Prefix-match entries expand per instance.
#
# Rule order is 1, 2, 4b, 3, 5, 4. The numbers are labels, not positions: Rule 5
# runs before Rule 4, and Rule 4b sits between Rule 2 and the supervisor probe.

set -euo pipefail

_WATCHDOG_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_WATCHDOG_DIR/../lib/lib.sh"
# shellcheck source=../lib/service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_WATCHDOG_DIR/../lib/service-health.sh"
# shellcheck source=../lib/svc-instances.sh
# WHY no guard variable: svc-instances.sh is a pure definition library, so
#   re-sourcing it is a no-op redefinition.
. "$_WATCHDOG_DIR/../lib/svc-instances.sh"

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

_oneshot=false
_scope_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
  --oneshot) _oneshot=true ;;
  --scope)
    [ $# -ge 2 ] || die "service-watchdog: --scope requires a value (user|system)"
    _scope_filter="$2"
    shift
    ;;
  --scope=*) _scope_filter="${1#--scope=}" ;;
  esac
  shift
done

_watchdog_main() {
  _watchdog_dispatch_supervisor

  local interval
  interval="$(_watchdog_interval_seconds)"
  while :; do
    _watchdog_tick
    if [ "$_oneshot" = true ]; then
      break
    fi
    sleep "$interval"
  done
}

# The plist injects the store path as NUCLEUS_SERVICES_JSON because a root
# launchd daemon cannot reach the repo: HOME is /var/root and the script lives
# in the Nix store. Derivation stays for interactive and test use.
_watchdog_services_json() {
  if [ -n "${NUCLEUS_SERVICES_JSON:-}" ]; then
    printf '%s' "$NUCLEUS_SERVICES_JSON"
    return 0
  fi
  printf '%s/src/modules/services.json' "$(derive_repo_root)"
}

_watchdog_interval_seconds() {
  local services_json="" value=""
  services_json="$(_watchdog_services_json)"
  if [ -f "$services_json" ]; then
    # WHY the quoted key: `cloud-drive` contains a hyphen, which jq parses as
    #   subtraction, so the unquoted form is a compile error that silently fell
    #   through to the default while the Windows twin honoured the same key.
    # check-suppress:suppression_doc: best-effort policy read; an absent lifecycle block falls back to the declared default
    value="$(jq -r '."cloud-drive".lifecycle.watchdogTickSeconds // empty' "$services_json" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-300}"
}

# Distinct from the tick interval, which bounds the gap between ticks.
_watchdog_repair_timeout_seconds() {
  local services_json="" value=""
  services_json="$(_watchdog_services_json)"
  if [ -f "$services_json" ]; then
    # WHY the quoted key: see _watchdog_interval_seconds.
    # check-suppress:suppression_doc: best-effort policy read; an absent lifecycle block falls back to the declared default
    value="$(jq -r '."cloud-drive".lifecycle.watchdogRepairTimeoutSeconds // empty' "$services_json" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-30}"
}

_watchdog_entry_field() {
  local entry="$1" path="$2" fallback="$3" value
  # check-suppress:suppression_doc: best-effort field read; a malformed entry falls back to the declared default
  value="$(printf '%s' "$entry" | jq -r "$path // empty" 2>/dev/null || true)"
  printf '%s' "${value:-$fallback}"
}

# WHY: the call sites are plain assignments inside plain-called functions, so
#   `set -e` is live at them and a non-zero jq status would kill the daemon
#   mid-tick, leaving every service after the corrupt one unchecked. The failure
#   is warned and returns empty, never a healthy default.
_watchdog_health_field() {
  local value
  if ! value="$(svc_health_get "$1" "$2")"; then
    warn "watchdog: unreadable health record for $1"
    printf ''
    return 0
  fi
  printf '%s' "$value"
}

# WHY: POSIX twin of the Windows writer (Write-NotLoadedNotice in
#   service-watchdog.ps1), reached from the same rule. The record's reportedState
#   suppresses repeats, so neither host needs a separate marker file.
_watchdog_not_loaded_notice() {
  local instance="$1"
  if [ "$(_watchdog_health_field "$instance" "state")" != "not-loaded" ]; then
    if ! svc_health_set_state "$instance" "not-loaded"; then
      warn "watchdog: could not record the not-loaded state for $instance"
    fi
  fi
  if ! svc_health_is_reported "$instance" "not-loaded"; then
    notice "watchdog: $instance is configured but not loaded (run 'nucleus-svc status $instance' or 'nucleus-apply')"
    if ! svc_health_mark_reported "$instance" "not-loaded"; then
      warn "watchdog: could not record the not-loaded notice for $instance"
    fi
  fi
}

# WHY: POSIX twin of Get-NucleusConfiguredInstanceList. An instance declared in
#   src/users/<user>/cloud-drives.json must be discovered from the registry and
#   not only from the supervisor, or it is invisible to the watchdog and can
#   never be reported. An unreadable registry yields nothing, not fabricated ids.
_watchdog_configured_instances() {
  local entry="$1" repo_root mounts
  repo_root="$(derive_repo_root)"
  if ! mounts="$(svc_configured_mounts "$repo_root" "$(resolve_nucleus_host)")"; then
    warn "watchdog: could not read the user registry; skipping configured-instance discovery"
    return 0
  fi
  svc_configured_instance_ids "$entry" "$mounts"
}

_watchdog_tick() {
  local services_json
  services_json="$(_watchdog_services_json)"
  [ -f "$services_json" ] || return 0

  local host_key
  host_key="$(resolve_nucleus_host)"

  local svc_keys
  # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
  svc_keys=$(jq -r 'keys[] | select(startswith("$") | not)' "$services_json" 2>/dev/null || true)

  local svc_key
  for svc_key in $svc_keys; do
    local host_entry
    # Service keys contain hyphens, which jq reads as subtraction in '.$key', so
    # both lookup parts bind with --arg and every service resolves.
    # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
    host_entry=$(jq -c --arg key "$svc_key" --arg host "$host_key" '.[$key].hosts[$host] // empty' "$services_json" 2>/dev/null || true)
    [ -n "$host_entry" ] || continue

    local svc_type
    svc_type="$(_watchdog_entry_field "$host_entry" '.type' '')"
    [ -n "$svc_type" ] || continue

    _watchdog_scope_selected "$host_entry" || continue

    local on_demand
    on_demand="$(_watchdog_entry_field "$host_entry" '.onDemand' 'false')"
    [ "$on_demand" = "true" ] && continue

    local prefix_match
    prefix_match="$(_watchdog_entry_field "$host_entry" '.prefixMatch' 'false')"

    if [ "$prefix_match" = "true" ]; then
      _watchdog_check_prefix "$svc_key" "$svc_type" "$host_entry"
    else
      local unit_name
      unit_name="$(_watchdog_entry_field "$host_entry" '.service' "$svc_key")"
      _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$svc_key" "$unit_name"
    fi
  done
}

# The instance id is the concrete unit/label, so expansion matches the service
# prefix directly: a launchd target is "<domain>/<uid>/<label>" and `launchctl
# list` prints labels only.
_watchdog_check_prefix() {
  local svc_key="$1" svc_type="$2" host_entry="$3"
  local service_name scope live_instances configured_instances instance

  service_name="$(_watchdog_entry_field "$host_entry" '.service' '')"
  [ -n "$service_name" ] || return 0

  case "$svc_type" in
  macos-launchctl)
    # check-suppress:suppression_doc: best-effort enumeration; an empty list is a valid answer, not a failure
    live_instances="$(launchctl list 2>/dev/null | awk -v p="$service_name" 'NR > 1 && index($0, p) > 0 {print $NF}' || true)"
    ;;
  nixos-systemctl)
    scope="$(_watchdog_entry_field "$host_entry" '.scope' 'user')"
    # check-suppress:suppression_doc: best-effort enumeration; an empty list is a valid answer, not a failure
    live_instances="$(systemctl "$(_watchdog_scope_flag "$scope")" list-units --type=service --all 2>/dev/null | awk -v p="$service_name" 'index($0, p) > 0 {print $1}' || true)"
    ;;
  *)
    # WHY: an unmatched type must skip the entry, not abort the tick. `live_instances`
    #   is a bare `local`, and an unassigned local is unbound under `set -u`
    #   (measured: rc=127), so reaching it below killed the whole tick instead of
    #   skipping one entry.
    return 0
    ;;
  esac

  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$instance"
  done <<<"$live_instances"

  # Instances the registry declares that the supervisor does not have. Passed as
  # configured so Rule 1 reports them instead of starting a unit that does not
  # exist. A live instance is skipped: it is already covered above.
  configured_instances="$(_watchdog_configured_instances "$host_entry")"
  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    svc_list_contains "$live_instances" "$instance" && continue
    _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$instance" "$instance" true
  done <<<"$configured_instances"
}

_watchdog_scope_flag() {
  if [ "${1:-user}" = "system" ]; then
    printf '%s' "--system"
  else
    printf '%s' "--user"
  fi
}

# WHY: one root daemon and one per-user agent run this same code, one per scope.
#   Ignoring the requested scope made each daemon cover the other's as well: the
#   user agent probed system units, found them not live (a user cannot read the
#   system manager), and reached for them through sudo, which cannot prompt inside
#   launchd, while the root daemon revived the user agent's own services.
_watchdog_scope_selected() {
  local entry_scope
  [ -n "$_scope_filter" ] || return 0
  entry_scope="$(_watchdog_entry_field "$1" '.scope' '')"
  # An entry with no declared scope is covered by both daemons, so the filter can
  # never orphan it.
  if [ -z "$entry_scope" ]; then
    return 0
  fi
  [ "$entry_scope" = "$_scope_filter" ]
}

# Args: $1 svc key, $2 host type, $3 host entry JSON, $4 health-record instance id,
# $5 supervisor unit name (defaults to $4), $6 configured (defaults to false).
_watchdog_check_instance() {
  local svc_key="$1" svc_type="$2" host_entry="$3" instance="$4"
  [ -n "$instance" ] || return 0
  local is_configured="${6:-false}"

  local target scope declared_unit_path unit_id
  # The supervisor addresses the declared unit name, which is not the health record
  # key: a single-unit service records health under its service key
  # (betterdisplay-heartbeat) while launchd/systemd address the declared
  # label/unit (local.betterdisplay-heartbeat, ollama.service). A prefix-match
  # family passes the concrete instance id, which is both.
  unit_id="${5:-$instance}"
  case "$svc_type" in
  macos-launchctl)
    scope="$(_watchdog_entry_field "$host_entry" '.scope' 'user')"
    # One definition of the target, shared with nucleus-svc; see
    # supervisor_resolve_target in macos-launch-services.sh for why the domain
    # follows from scope rather than from launchdDomain alone.
    target="$(supervisor_resolve_target "$scope" "$(_watchdog_entry_field "$host_entry" '.launchdDomain' 'gui')" "$unit_id")"
    ;;
  nixos-systemctl)
    target="$unit_id"
    scope="$(_watchdog_entry_field "$host_entry" '.scope' 'user')"
    ;;
  *)
    return 0
    ;;
  esac

  # WHY this is read before Rule 1: supervisor_enabled consumes it too, so a job
  #   whose file sits at a declared non-default path is still found, and the
  #   Rule 1 decision depends on that answer.
  declared_unit_path="$(_watchdog_entry_field "$host_entry" '.unitPath' '')"

  # Rule 1: explicitly disabled by the user, or absent. Only a manual re-enable
  # (nucleus-apply) changes this. The Windows twin (Test-ServiceInstance Rule 1)
  # additionally classifies a registry-declared instance with no unit as
  # not-loaded, reported once instead of started.
  if ! supervisor_enabled "$target" "$declared_unit_path" "$scope"; then
    if [ "$is_configured" = true ]; then
      _watchdog_not_loaded_notice "$instance"
    fi
    return 0
  fi

  if svc_health_is_blocked "$instance"; then
    local class remedy _blocked_state
    class=$(svc_health_get "$instance" "class" 2>/dev/null || echo "unknown")
    _blocked_state="$(_watchdog_health_field "$instance" "state")"
    if ! svc_health_is_reported "$instance" "${_blocked_state}:${class}"; then
      remedy=$(svc_health_get "$instance" "remedy" 2>/dev/null || echo "")
      notice "watchdog: $instance is blocked ($class): $remedy"
      if ! svc_health_mark_reported "$instance" "${_blocked_state}:${class}"; then
        warn "watchdog: could not record the blocked notice for $instance"
      fi
    fi
    return 0
  fi

  # Rule 4b: the record, not the probe, is the input. The classification is
  # written by whichever tick found the instance missing (Rule 1), and only
  # nucleus-apply re-arms it.
  local _state
  _state="$(_watchdog_health_field "$instance" "state")"
  if [ "$_state" = "not-loaded" ]; then
    _watchdog_not_loaded_notice "$instance"
    return 0
  fi

  # Both backends expose the same arity, so only the status command differs.
  local is_live=false print_out="" generation="" last_exit=0 repair_timeout=0 repair_rc=0
  case "$svc_type" in
  macos-launchctl)
    # check-suppress:suppression_doc: best-effort probe; absent output simply means not live
    print_out=$(launchctl print "$target" 2>/dev/null || true)
    ;;
  nixos-systemctl)
    # check-suppress:suppression_doc: best-effort probe; absent output simply means not live
    print_out=$(systemctl "$(_watchdog_scope_flag "$scope")" status "$target" 2>/dev/null || true)
    ;;
  esac
  if supervisor_live "$print_out"; then
    is_live=true
  fi
  # check-suppress:suppression_doc: best-effort probe; the backends report zero when there is nothing to read
  generation=$(supervisor_generation "$target" "$scope" || true)
  # check-suppress:suppression_doc: best-effort probe; the backends report zero when there is nothing to read
  last_exit=$(supervisor_last_exit "$target" "$scope" || true)
  generation="${generation:-0}"
  last_exit="${last_exit:-0}"

  if [ "$is_live" = true ]; then
    # The health record is the only place a restart is counted, so the generation
    # token is compared against the last observation on every tick.
    local stored
    stored="$(_watchdog_health_field "$instance" "generation")"

    # An absent generation has never been observed: adopt the token and record
    # nothing, so a cold start is never mistaken for a restart. A token that
    # legitimately reads zero is still compared, or the first restart is swallowed.
    if [ -n "$stored" ]; then
      if [ "$generation" != "$stored" ]; then
        # WHY: one restart per observed change, never (current - stored). The token
        #   is a run count on launchd and systemd but process identity or a run
        #   time on Windows, where the difference is elapsed seconds and would
        #   fabricate thousands of restarts out of one.
        if ! svc_health_record_restart "$instance" "supervisor"; then
          warn "watchdog: could not record a restart for $instance"
        fi
      else
        if ! svc_health_record_success "$instance"; then
          warn "watchdog: could not record success for $instance"
        fi
      fi
    fi

    if ! svc_health_set "$instance" "generation" "$generation"; then
      warn "watchdog: could not record the generation for $instance"
    fi
    if ! svc_health_set_last_exit "$instance" "$last_exit"; then
      warn "watchdog: could not record the last exit for $instance"
    fi

    if svc_health_is_looping "$instance"; then
      notice "watchdog: $instance is looping (generation=$generation, last_exit=$last_exit); stopping"
      if ! svc_health_set_blocked "$instance" "crash-loop" "supervisor is restarting the job in a loop"; then
        warn "watchdog: could not record the block for $instance"
      fi
      # The block is recorded either way, so a failed unload is reported rather
      # than fatal, and the next tick retries it.
      if ! supervisor_stop "$target" "$scope"; then
        warn "watchdog: could not unload $instance after blocking it"
      fi
      return 0
    fi

    case "$last_exit" in
    78)
      notice "watchdog: $instance exited with EX_CONFIG (78); repairing"
      # WHY the bound: a repair that hangs, such as one blocked inside the kernel by a
      #   dead macFUSE volume, would stall the tick and leave every instance after
      #   this one unchecked. 124 is svc_run_bounded's timeout status.
      repair_timeout="$(_watchdog_repair_timeout_seconds)"
      svc_run_bounded "$repair_timeout" supervisor_repair "$target" "$declared_unit_path" "$scope" || repair_rc=$?
      if [ "$repair_rc" -eq 124 ]; then
        warn "watchdog: repair of $instance timed out after ${repair_timeout}s"
      elif [ "$repair_rc" -ne 0 ]; then
        warn "watchdog: could not repair $instance (status $repair_rc)"
      fi
      return 0
      ;;
    esac

    return 0
  fi

  notice "watchdog: $instance is not running; starting"
  if ! supervisor_start "$target" "$declared_unit_path" "$scope"; then
    warn "watchdog: could not start $instance"
  fi
}

_watchdog_main "$@"
