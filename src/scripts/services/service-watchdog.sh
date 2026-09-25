#!/usr/bin/env bash
# shellcheck shell=bash
# Service watchdog — detects and breaks loops, revives stopped services.
# Rewritten for the cloud-mount rewrite: one rule table, all hosts, no OS names.
#
# Rules (identical on every host), listed in the order they are EVALUATED.
# The numbers are names, not positions: Rule 5 runs before Rule 4, and Rule 4b
# sits between Rule 2 and the supervisor probe.
#   1. user-disabled → skip (explicit user intent, documented)
#   2. Blocked record exists → report once, do nothing
#   4b. record already says not-loaded → report once, no action until apply
#   3. supervisor_live + looping → block + stop
#   5. Live + broken (EX_CONFIG 78 etc) → repair
#   4. Not live + not blocked → start (revival — the only mechanism)
#
# Reads services.json, filters to the current host and to the requested scope,
# skips on-demand services.  Prefix-match entries are expanded per instance.
#
# Runs indefinitely, sleeping the cloud-drive lifecycle's watchdogTickSeconds between
# ticks (persistent daemon).  Use --oneshot for a single iteration (manual or CI).
# Use --scope user|system to cover one launchd/systemd domain; without it every
# scope on this host is covered.

set -euo pipefail

_WATCHDOG_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_WATCHDOG_DIR/../lib/lib.sh"
# shellcheck source=../lib/service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_WATCHDOG_DIR/../lib/service-health.sh"
# shellcheck source=../lib/svc-instances.sh
# WHY: no guard variable — svc-instances.sh is a pure definition library with no
#   top-level side effects (stated in its own header), so re-sourcing it is a
#   no-op redefinition. Its header names this watchdog as a consumer; the
#   configured-instance enumeration below is the call site it refers to.
. "$_WATCHDOG_DIR/../lib/svc-instances.sh"

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
# The two macOS launchd jobs pass one --scope each (the root system daemon and
# the per-user agent), so scope selects WHICH entries a daemon covers rather
# than being a decorative flag.  An absent --scope covers every scope, which is
# what a manual --oneshot run wants.
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

# Main loop.
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

# Path to the services registry this watchdog reads.
# The plist injects the store path as NUCLEUS_SERVICES_JSON because a root
# launchd daemon cannot reach the repo: HOME is /var/root and the script itself
# lives in the Nix store, so derivation has nothing to walk.  Preferring the
# injected path is what makes the deployed daemon functional; derivation stays
# for interactive and test use, where no such variable is set.
_watchdog_services_json() {
  if [ -n "${NUCLEUS_SERVICES_JSON:-}" ]; then
    printf '%s' "$NUCLEUS_SERVICES_JSON"
    return 0
  fi
  printf '%s/src/modules/services.json' "$(derive_repo_root)"
}

# Seconds between ticks — how long a service may stay down before revival is even
# attempted.  Reading it keeps the interval from drifting away from the policy
# declared in services.json.
_watchdog_interval_seconds() {
  local services_json="" value=""
  services_json="$(_watchdog_services_json)"
  if [ -f "$services_json" ]; then
    # WHY the quoted key: `cloud-drive` contains a hyphen, which jq parses as
    #   subtraction — `.cloud-drive...` is a COMPILE error (drive/0 is not defined),
    #   so the unquoted form silently fell through to the default below and the
    #   declared value was never read on POSIX.  The Windows twin reads the same key
    #   by name and honoured it, so the two hosts disagreed while both claimed to read
    #   one policy.
    # check-suppress:suppression_doc: best-effort policy read; an absent lifecycle block falls back to the declared default
    value="$(jq -r '."cloud-drive".lifecycle.watchdogTickSeconds // empty' "$services_json" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-300}"
}

# Seconds allowed for ONE supervisor repair call before it is abandoned as timed
# out.  Distinct from the tick interval above, which bounds the gap BETWEEN ticks.
_watchdog_repair_timeout_seconds() {
  local services_json="" value=""
  services_json="$(_watchdog_services_json)"
  if [ -f "$services_json" ]; then
    # WHY the quoted key: see _watchdog_interval_seconds — an unquoted hyphenated key
    #   is a jq compile error, so this reader used to return the default unconditionally
    #   and the declared repair bound never reached svc_run_bounded on POSIX.
    # check-suppress:suppression_doc: best-effort policy read; an absent lifecycle block falls back to the declared default
    value="$(jq -r '."cloud-drive".lifecycle.watchdogRepairTimeoutSeconds // empty' "$services_json" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-30}"
}

# Read one field from a host entry as a raw string.
# Args: $1 — host entry JSON; $2 — jq path; $3 — default when absent.
_watchdog_entry_field() {
  local entry="$1" path="$2" fallback="$3" value
  # check-suppress:suppression_doc: best-effort field read; a malformed entry falls back to the declared default
  value="$(printf '%s' "$entry" | jq -r "$path // empty" 2>/dev/null || true)"
  printf '%s' "${value:-$fallback}"
}

# Read one health-record field without letting a corrupt record abort the tick.
# WHY: the call sites are PLAIN assignments inside plain-called functions, so
#   `set -e` is live at them. A non-zero jq status would kill the daemon
#   mid-tick and leave EVERY service after the corrupt one unchecked — the same
#   class as the supervisor-parser crash, one layer down. The failure is warned
#   and an empty value returned, never a healthy default, so a corrupt record
#   can never read as "fine".
# Args: $1 — instance id; $2 — field name.
_watchdog_health_field() {
  local value
  if ! value="$(svc_health_get "$1" "$2")"; then
    warn "watchdog: unreadable health record for $1"
    printf ''
    return 0
  fi
  printf '%s' "$value"
}

# Record and report "configured but not loaded" for one instance, once.
# WHY: the POSIX twin of the Windows writer (Write-NotLoadedNotice in
#   service-watchdog.ps1), reached from the same place — the rule that declines
#   to start a service the registry declares but the supervisor does not have.
#   The record's reportedState suppresses repeats, so neither host needs a
#   separate marker file.
# Args: $1 — health-record instance id.
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

# Instances the user registry declares for one prefix-match entry.
# WHY: the POSIX twin of Get-NucleusConfiguredInstanceList. An instance declared
#   in src/users/<user>/cloud-drives.json is expected to run even while no unit
#   exists for it, so discovery must read the registry and not only the
#   supervisor — otherwise such an instance is invisible to the watchdog and can
#   never be reported. svc-instances.sh owns the registry-to-instance mapping.
#   A registry that cannot be read yields nothing rather than fabricated ids.
# Args: $1 — host entry JSON.
_watchdog_configured_instances() {
  local entry="$1" repo_root mounts
  repo_root="$(derive_repo_root)"
  if ! mounts="$(svc_configured_mounts "$repo_root" "$(resolve_nucleus_host)")"; then
    warn "watchdog: could not read the user registry; skipping configured-instance discovery"
    return 0
  fi
  svc_configured_instance_ids "$entry" "$mounts"
}

# One tick: check all services on this host.
_watchdog_tick() {
  local services_json
  services_json="$(_watchdog_services_json)"
  [ -f "$services_json" ] || return 0

  local host_key
  host_key="$(resolve_nucleus_host)"

  # Resolve all service keys BEFORE the loop (D5 fix).
  local svc_keys
  # check-suppress:suppression_doc: best-effort operation; failure is non-fatal
  svc_keys=$(jq -r 'keys[] | select(startswith("$") | not)' "$services_json" 2>/dev/null || true)

  local svc_key
  for svc_key in $svc_keys; do
    local host_entry
    # Service keys contain hyphens, which jq reads as subtraction in ".$key" —
    # bind both lookup parts with --arg so every service resolves.
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
      # Health is keyed by the service key; the supervisor addresses the
      # declared unit name (e.g. local.ollama, ollama.service).
      local unit_name
      unit_name="$(_watchdog_entry_field "$host_entry" '.service' "$svc_key")"
      _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$svc_key" "$unit_name"
    fi
  done
}

# Check all instances for a prefix-match service.
# The instance id is the concrete unit/label, so expansion matches the service
# prefix directly — a launchd target is "<domain>/<uid>/<label>", never the
# label alone, and `launchctl list` prints labels only.
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
    #   is a bare `local`, and an unassigned local is UNBOUND under `set -u`
    #   (measured: rc=127), so reaching `$live_instances` below killed the whole
    #   tick instead of skipping one entry. This mirrors `_watchdog_check_instance`'s
    #   own `*) return 0` arm — and returns identically, because that sibling returns
    #   0 for an unknown type too, so the configured-instance loop below could never
    #   have done anything with it either.
    return 0
    ;;
  esac

  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$instance"
  done <<<"$live_instances"

  # Instances the registry declares that the supervisor does not have. They are
  # passed as configured so Rule 1 reports them instead of trying to start a unit
  # that does not exist. An instance that is live is skipped: it is already
  # covered above and is not "missing".
  configured_instances="$(_watchdog_configured_instances "$host_entry")"
  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    svc_list_contains "$live_instances" "$instance" && continue
    _watchdog_check_instance "$svc_key" "$svc_type" "$host_entry" "$instance" "$instance" true
  done <<<"$configured_instances"
}

# Map a declared scope to the systemctl flag selecting that manager.
_watchdog_scope_flag() {
  if [ "${1:-user}" = "system" ]; then
    printf '%s' "--system"
  else
    printf '%s' "--user"
  fi
}

# _watchdog_scope_selected — 0 when this invocation covers the entry's scope.
# WHY: one root daemon and one per-user agent run this same code, one per scope.
#   Ignoring the requested scope made each daemon cover the other's as well: the
#   user agent then probed system units, found them not live (a user cannot read
#   the system manager), and reached for them through sudo — which cannot prompt
#   inside launchd — while the root daemon revived the user agent's own services
#   at the same time.  An entry that declares no scope is covered by both, so it
#   can never be silently orphaned.
# Args: $1 — host entry JSON.
_watchdog_scope_selected() {
  local entry_scope
  [ -n "$_scope_filter" ] || return 0
  entry_scope="$(_watchdog_entry_field "$1" '.scope' '')"
  # An entry that declares no scope is covered by both daemons, so it can never
  # be silently orphaned by the filter.
  if [ -z "$entry_scope" ]; then
    return 0
  fi
  [ "$entry_scope" = "$_scope_filter" ]
}

# Check one instance.
# Args: $1 — service key; $2 — host type; $3 — host entry JSON;
#       $4 — health-record instance id;
#       $5 — supervisor unit name (optional; defaults to $4).
_watchdog_check_instance() {
  local svc_key="$1" svc_type="$2" host_entry="$3" instance="$4"
  [ -n "$instance" ] || return 0
  # $6 — true when the user registry declares this instance but the supervisor
  # has no unit for it; the POSIX twin of the Windows IsConfigured flag.
  local is_configured="${6:-false}"

  local target scope declared_unit_path unit_id
  # The supervisor addresses the declared unit name, which is not the health
  # record key: a single-unit service records health under its service key
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

  # Declared unit path from services.json; the backend expands __INSTANCE__ and ~.
  # WHY this is read before Rule 1: supervisor_enabled consumes it too — it is
  #   what lets the predicate find a job whose file sits at a declared non-default
  #   path, and Rule 1's skip decision depends on that answer. Reading it here
  #   also keeps it away from a bare `local` being UNBOUND under `set -u`, which
  #   would abort the whole tick instead of skipping one instance.
  declared_unit_path="$(_watchdog_entry_field "$host_entry" '.unitPath' '')"

  # Rule 1: is the service explicitly disabled by the user, or absent?
  # A disabled service must not be auto-started; only a manual re-enable
  # (nucleus-apply) changes this.  The Windows twin (Test-ServiceInstance Rule 1)
  # additionally classifies an instance the registry declares but the supervisor
  # does not have as not-loaded, and reports it once instead of starting it.
  if ! supervisor_enabled "$target" "$declared_unit_path" "$scope"; then
    if [ "$is_configured" = true ]; then
      _watchdog_not_loaded_notice "$instance"
    fi
    return 0
  fi

  # Rule 2: blocked record?
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

  # Rule 4b: not-loaded record → informational only (no action until nucleus-apply).
  # The record, not the probe, is the input: the classification is written by
  # whichever tick found the instance missing (Rule 1), and only nucleus-apply
  # re-arms it.
  local _state
  _state="$(_watchdog_health_field "$instance" "state")"
  if [ "$_state" = "not-loaded" ]; then
    _watchdog_not_loaded_notice "$instance"
    return 0
  fi

  # Probe the supervisor. Both backends expose the same arity, so there is no
  # per-type branching beyond the status command itself.
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
    # Rule 3's input is folded in here: the health record is the only place a
    # restart is counted, so the supervisor's generation token is compared
    # against the last observation on every tick.  A token that changed between
    # ticks means the supervisor started a new run; an unchanged token means the
    # instance survived the whole tick.
    local stored
    stored="$(_watchdog_health_field "$instance" "generation")"

    # A null/absent generation has never been observed: adopt the token and
    # record nothing, so a cold start is never mistaken for a restart.  Only a
    # missing value counts as unobserved — a token that legitimately reads zero
    # must still be compared, or the service's first restart would be swallowed.
    if [ -n "$stored" ]; then
      if [ "$generation" != "$stored" ]; then
        # WHY: one restart per observed change, never (current - stored).  The
        #   token is a run count on launchd and systemd, but process identity or
        #   a run *time* on Windows, where the difference is elapsed seconds and
        #   would fabricate thousands of restarts out of a single one.  Both
        #   platforms must agree, so the comparison is inequality only.
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
      # Health-record-driven loop detection: covers both counter-incrementing
      # restart loops and self-looping daemons (e.g. betterdisplay-heartbeat).
      notice "watchdog: $instance is looping (generation=$generation, last_exit=$last_exit); stopping"
      if ! svc_health_set_blocked "$instance" "crash-loop" "supervisor is restarting the job in a loop"; then
        warn "watchdog: could not record the block for $instance"
      fi
      # The block is recorded either way, so a failed unload is reported rather
      # than fatal — the next tick retries it.
      if ! supervisor_stop "$target" "$scope"; then
        warn "watchdog: could not unload $instance after blocking it"
      fi
      return 0
    fi

    # Rule 5: live but last exit was EX_CONFIG (78) → repair.
    case "$last_exit" in
    78)
      notice "watchdog: $instance exited with EX_CONFIG (78); repairing"
      # WHY the bound: a repair that hangs — a dead macFUSE volume blocks inside the
      #   kernel — would otherwise stall the whole tick, and every instance after this
      #   one would go unchecked.  124 is svc_run_bounded's timeout status.
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

    # Stable.
    return 0
  fi

  # Rule 4: not live + not blocked → revival via supervisor_start.
  notice "watchdog: $instance is not running; starting"
  if ! supervisor_start "$target" "$declared_unit_path" "$scope"; then
    warn "watchdog: could not start $instance"
  fi
}

_watchdog_main "$@"
