#!/usr/bin/env bash
# Provides a uniform CLI for listing, starting, stopping, restarting,
# enabling, and disabling services across macOS (launchctl) and NixOS (systemctl).
# Services are defined in src/modules/services.json (the canonical registry).

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
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
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

usage() {
  usage_std "$(basename "$0")" "list|status|start|stop|restart|enable|disable|verify|endpoint|logs|log-paths|log-config [service...] [options]"
  cat <<'EOF'
  list                              List all known services with status.
  status [service...]               Show status of specified services (all if omitted).
  start <service>                   Start a service.
  stop <service>                    Stop a service.
  restart <service>                 Restart a service.
  enable <service>                  Enable auto-start.
  disable <service>                 Disable auto-start.
  verify [service...]               Check all (or specified) services, warn if inactive.
  endpoint <service> [<name>]       Show network endpoint(s) for a service.
  logs [service...]                 Show service logs (list available if no service).
  log-paths [service...]            Print log file path(s).
  log-config [service...]           Show effective logging configuration.
  --json                            Machine-readable JSON output.
  --verbose                         Show action result summaries (start/restart).
  -h|--help                         Show usage.
EOF
}

REPO_ROOT="$(derive_repo_root)"
SERVICES_JSON="$REPO_ROOT/src/modules/services.json"
HOST="$(resolve_nucleus_host)"

# Map resolve_nucleus_host output to services.json platform key
case "$HOST" in
  MacBook) PLATFORM="macos" ;;
  NixOS)   PLATFORM="nixos" ;;
  *)       error "unsupported host '$HOST'" ;;
esac

# Helpers

# read_registry — Parse services.json and return JSON filtered to current platform.
read_registry() {
  if [ ! -f "$SERVICES_JSON" ]; then
    error "services registry not found at $SERVICES_JSON"
  fi
  require_command jq
  jq -c --arg platform "$PLATFORM" '
    to_entries | map(
      select(.value | type == "object")
      | select(.value.platforms | has($platform))
      | select(.value.platforms[$platform].type != "omitted")
      | {key: .key, value: {displayName: .value.displayName, description: .value.description, network: .value.network, platform: .value.platforms[$platform]}}
    ) | from_entries
  ' "$SERVICES_JSON"
}

# resolve_service_names — Given user-specified names, resolve prefix matches to concrete names.
# Outputs newline-separated entries of form: key\tdisplayName\tplatformJson
resolve_service_names() {
  local registry="$1"
  shift
  local names=("$@")

  if [ "${#names[@]}" -eq 0 ]; then
    # Return all services, expanding prefix matches to concrete names
    while IFS=$'\t' read -r key display plat_json; do
      local prefix_match
      prefix_match=$(echo "$plat_json" | jq -r '.prefixMatch // false')
      if [ "$prefix_match" = "true" ]; then
        local prefix entries
        prefix=$(echo "$plat_json" | jq -r '.service')
        entries=$(expand_prefix "$key" "$prefix" "$plat_json")
        printf '%s\n' "$entries"
      else
        printf '%s\t%s\t%s\t%s\n' "$key" "$display" "$plat_json" "$key"
      fi
    done < <(echo "$registry" | jq -r 'to_entries[] | [.key, .value.displayName, (.value.platform | tojson)] | @tsv')
    return
  fi

  for name in "${names[@]}"; do
    local entry
    entry=$(echo "$registry" | jq -c --arg name "$name" '.[$name] // empty')
    if [ -n "$entry" ]; then
      local prefix_match
      prefix_match=$(echo "$entry" | jq -r '.platform.prefixMatch // false')
      if [ "$prefix_match" = "true" ]; then
        local prefix
        prefix=$(echo "$entry" | jq -r '.platform.service')
        local entries
        entries=$(expand_prefix "$name" "$prefix" "$(echo "$entry" | jq -c '.platform')")
        printf '%s\n' "$entries"
      else
        printf '%s\n' "$name	$(echo "$entry" | jq -r '.displayName')	$(echo "$entry" | jq -c '.platform')	$name"
      fi
    else
      printf '%s\n' "ERROR:unknown	$name	{\"error\":\"service not found in registry\"}	ERROR:unknown"
    fi
  done
}

# expand_prefix — List concrete services matching a prefix on the current platform.
# Outputs tab-separated lines: key\tserviceId\tplatformJson
expand_prefix() {
  local name="$1" prefix="$2" plat_json="$3"
  case "$PLATFORM" in
    macos)
      local sudo_prefix=""
      local domain
      domain=$(echo "$plat_json" | jq -r '.domain // "user"')
      [ "$domain" = "system" ] && sudo_prefix="sudo"
      local matches
      # undoc-supp: no matching services found is an expected empty result, not an error.
      matches=$($sudo_prefix launchctl list 2>/dev/null | awk -v p="$prefix" '$3 ~ p { print $3 }' || true)
      if [ -z "$matches" ]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$prefix" "$plat_json" "$name"
      else
        while IFS= read -r m; do
          printf '%s\t%s\t%s\t%s\n' "$name" "$m" "{\"type\":\"launchctl\",\"service\":\"$m\",\"domain\":\"$(echo "$plat_json" | jq -r '.domain')\"}" "$m"
        done <<< "$matches"
      fi
      ;;
    nixos)
      local scope_flag=""
      [ "$(echo "$plat_json" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"
      local matches
      # undoc-supp: no matching units found is an expected empty result.
      matches=$(systemctl $scope_flag list-units --all "$prefix*" --no-legend 2>/dev/null | awk '{ print $1 }' || true)
      if [ -z "$matches" ]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$prefix" "$plat_json" "$name"
      else
        while IFS= read -r m; do
          printf '%s\t%s\t%s\t%s\n' "$name" "$m" "{\"type\":\"systemctl\",\"service\":\"$m\",\"scope\":\"$(echo "$plat_json" | jq -r '.scope')\"}" "$m"
        done <<< "$matches"
      fi
      ;;
  esac
}

# svc_status — Print JSON status for a single service entry.
svc_status() {
  local name="$1"
  local entry_json="$2"

  local svc_type svc_id scope_flag=""
  svc_type=$(echo "$entry_json" | jq -r '.type')
  svc_id=$(echo "$entry_json" | jq -r '.service // .taskPath // ""')

  case "$svc_type" in
    launchctl)
      local domain_flag=""
      local domain
      domain=$(echo "$entry_json" | jq -r '.domain // "user"')
      [ "$domain" = "system" ] && domain_flag="sudo"

      local list_line running=true enabled=true pid=""
      # undoc-supp: service may not exist or may never have started; probe expected to fail.
      list_line=$($domain_flag launchctl list 2>/dev/null | awk -v label="$svc_id" 'NR>1 && $3==label { print $1, $2 }' || true)
      local socket_activated
      socket_activated=$(echo "$entry_json" | jq -r '.socketActivated // false')
      if [ -z "$list_line" ]; then
        running=false; enabled=false
      else
        pid=$(echo "$list_line" | awk '{ print $1 }')
        if [ "$pid" = "-" ] || [ -z "$pid" ]; then pid=""; fi
        local last_exit
        last_exit=$(echo "$list_line" | awk '{ print $2 }')
        if [ -z "$pid" ] && [ "$last_exit" != "0" ]; then
          running=false
        fi
      fi
      # Fallback: if the basic check says inactive but launchctl print says
      # the service is actually running (transient state in launchctl list),
      # trust the authoritative print output.
      if [ "$running" != "true" ]; then
        local print_out
        # undoc-supp: service may not exist or may never have started; probe expected to fail.
        print_out=$($domain_flag launchctl print "$(launchctl_target "$domain" "$svc_id")" 2>/dev/null || true)
        case "$print_out" in
          *"state = running"*)
            running=true; enabled=true
            pid=$(echo "$print_out" | sed -n 's/.*pid = \([0-9]*\).*/\1/p')
            [ -z "$pid" ] && pid=""
            ;;
        esac
      fi
      local status_text state_text exit_code=""
      if [ "$running" = true ]; then
        status_text="active"
      elif [ "$socket_activated" = "true" ]; then
        status_text="listening"
      else
        status_text="inactive"
        # Capture state and exit code from print output for diagnostics.
        state_text=$(echo "$print_out" | sed -n 's/.*state = //p' | head -1)
        exit_code=$(echo "$print_out" | sed -n 's/.*last exit code = //p' | head -1 | sed 's/:.*//')
      fi
      printf '{"status":"%s","running":%s,"enabled":%s,"pid":%s,"state":%s,"exitCode":%s}' \
        "$status_text" \
        "$running" "$enabled" "${pid:-null}" \
        "$(printf '%s' "${state_text:-null}" | jq -R . 2>/dev/null || echo null)" \
        "${exit_code:-null}"
      ;;
    systemctl)
      local scope_flag=""
      [ "$(echo "$entry_json" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"

      local is_active is_enabled
      # undoc-supp: unit may not exist on this system; probe expected to fail.
      is_active=$(systemctl $scope_flag is-active "$svc_id" 2>/dev/null || true)
      is_active="${is_active:-inactive}"
      # undoc-supp: unit may not exist on this system; probe expected to fail.
      is_enabled=$(systemctl $scope_flag is-enabled "$svc_id" 2>/dev/null || true)
      is_enabled="${is_enabled:-disabled}"

      local running=true
      [ "$is_active" != "active" ] && running=false
      local enabled_bool=true
      [ "$is_enabled" != "enabled" ] && enabled_bool=false

      local pid="" exit_code=""
      if [ "$running" = true ]; then
        # undoc-supp: unit may not exist on this system; probe expected to fail.
        pid=$(systemctl $scope_flag show -p MainPID "$svc_id" 2>/dev/null | sed 's/MainPID=//' || true)
        [ -z "$pid" ] || [ "$pid" = "0" ] && pid=""
      else
        # undoc-supp: unit may not exist on this system; probe expected to fail.
        exit_code=$(systemctl $scope_flag show -p ExecMainStatus "$svc_id" 2>/dev/null | sed 's/ExecMainStatus=//' || true)
        [ -z "$exit_code" ] && exit_code=""
      fi
      printf '{"status":"%s","running":%s,"enabled":%s,"pid":%s,"state":%s,"exitCode":%s}' \
        "$is_active" "$running" "$enabled_bool" "${pid:-null}" \
        "$(printf '%s' "$is_active" | jq -R . 2>/dev/null || echo null)" \
        "${exit_code:-null}"
      ;;
    *)
      printf '{"status":"unknown","running":false,"enabled":false,"pid":null}'
      ;;
  esac
}

# recover_launchctl_service — Recover a launchctl service stuck in
# spawn-scheduled / waiting / EX_CONFIG state.
# Does bootout+bootstrap to fully reload. Returns 0 if recovery was done.
#
# Handles three cases that `launchctl start` alone cannot fix:
#   • state = spawn scheduled   — server shutdown left service in limbo
#   • state = waiting           — service exited with a terminal code
#   • last exit code = 78       — EX_CONFIG: launchd won't retry
# In all cases a full bootout+bootstrap cycle is required to clear the exit
# memory and let launchd try again.
#
# On macOS 26+, SIP blocks unsigned Nix store binaries for system daemons
# with non-root UserName, producing exit 78 at boot. All MacBook daemons use
# /bin/sh wrapper to pass SIP gate
# (.agents/instructions/macos-launchd-sip.instructions.md).
recover_launchctl_service() {
  local domain="$1" svc_id="$2" sudo_prefix="$3"
  local target
  target=$(launchctl_target "$domain" "$svc_id")
  local print_out
  # undoc-supp: service may not exist or may never have started; probe expected to fail.
  print_out=$($sudo_prefix launchctl print "$target" 2>/dev/null || true)
  case "$print_out" in
    *"state = spawn scheduled"*|*"state = waiting"*|*"last exit code = 78"*)
      local plist
      if [ "$domain" = "system" ]; then
        plist="/Library/LaunchDaemons/$svc_id.plist"
      else
        plist="$HOME/Library/LaunchAgents/$svc_id.plist"
      fi
      # undoc-supp: service may not be loaded; bootout on absent service exits 1.
      $sudo_prefix launchctl bootout "$target" 2>/dev/null || true
      # If bootstrap fails (e.g. launchd still cleaning up from bootout),
      # return 1 so the caller's || block retries with the full
      # graceful-shutdown path (SIGTERM + wait + bootout + bootstrap).
      if $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$domain")" "$plist" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
  esac
  return 1
}

# poll_service_status — Poll svc_status until running or timeout (~4s).
# Returns the final status JSON on stdout. Exit 0 if running, 1 if still inactive.
poll_service_status() {
  local name="$1" entry_json="$2"
  for _i in 1 2 3 4 5 6 7 8; do
    local status_json
    status_json=$(svc_status "$name" "$entry_json")
    local running
    running=$(echo "$status_json" | jq -r '.running')
    if [ "$running" = "true" ]; then
      printf '%s\n' "$status_json"
      return 0
    fi
    sleep 0.5
  done
  printf '%s\n' "$status_json"
  return 1
}

# poll_service_ready — Poll for service manager readiness AND port readiness.
# Runs poll_service_status first, then verifies all registered ports are
# actually listening. Returns 0 only when both checks pass.
poll_service_ready() {
  _psr_name="$1"
  _psr_entry_json="$2"

  local _psr_status_json
  _psr_status_json=$(poll_service_status "$_psr_name" "$_psr_entry_json") || {
    printf '%s\n' "$_psr_status_json"
    return 1
  }

  local _psr_ports
  # undoc-supp: port may not be occupied by this service; extract_ports returns empty for no-network entries.
  _psr_ports=$(extract_ports "$_psr_entry_json") || true
  if [ -n "$_psr_ports" ]; then
    while IFS=' ' read -r _psr_host _psr_port; do
      wait_for_port "$_psr_port" "$_psr_host" 5 || {
        warn "$_psr_name — running but port $_psr_port ($_psr_host) not listening"
        printf '%s\n' "$_psr_status_json"
        return 1
      }
    done <<EOF
$_psr_ports
EOF
  fi

  printf '%s\n' "$_psr_status_json"
  return 0
}

# service_diagnostic — Print one-line diagnostic for a failing service.
# Reads launchctl print / systemctl status and extracts state + exit code.
service_diagnostic() {
  local entry_json="$1"
  local svc_type svc_id
  svc_type=$(echo "$entry_json" | jq -r '.type')
  svc_id=$(echo "$entry_json" | jq -r '.service // ""')
  case "$svc_type" in
    launchctl)
      local domain sudo_prefix="" target
      domain=$(echo "$entry_json" | jq -r '.domain // "user"')
      [ "$domain" = "system" ] && sudo_prefix="sudo"
      target=$(launchctl_target "$domain" "$svc_id")
      $sudo_prefix launchctl print "$target" 2>/dev/null \
        | awk -F'= ' '/state =/{s=$2} /last exit code/{e=$NF} END{printf "state=%s", s; if(e) printf ", exit=%s", e; printf "\n"}'
      ;;
    systemctl)
      local scope_flag=""
      [ "$(echo "$entry_json" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"
      systemctl $scope_flag --no-pager -l status "$svc_id" 2>&1 \
        | sed -n 's/.*Active: //p' | head -1
      ;;
  esac
}

# cleanup_service_ports — Free ports registered for a service by killing
# any rogue process holding them. Handles manual starts, orphans from
# previous wrappers, etc. that are outside the service manager's kill domain.
cleanup_service_ports() {
  _csp_entry_json="$1"
  # undoc-supp: port may not be occupied by this service; extract_ports returns empty for no-network entries.
  _csp_ports=$(extract_ports "$_csp_entry_json") || true
  [ -z "$_csp_ports" ] && return 0
  while IFS=' ' read -r _csp_host _csp_port; do
    # undoc-supp: port may not be occupied by this service; extract_ports returns empty for no-network entries.
    kill_processes_on_port "$_csp_port" || true
  done <<EOF
$_csp_ports
EOF
}

# svc_action — Perform an action on a single service.
svc_action() {
  local action="$1"
  local name="$2"
  local entry_json="$3"

  local svc_type svc_id
  svc_type=$(echo "$entry_json" | jq -r '.type')
  svc_id=$(echo "$entry_json" | jq -r '.service // .taskPath // ""')

  case "$svc_type" in
    launchctl)
      local domain
      domain=$(echo "$entry_json" | jq -r '.domain // "user"')
      local sudo_prefix=""
      [ "$domain" = "system" ] && sudo_prefix="sudo"
      local target
      target=$(launchctl_target "$domain" "$svc_id")

      local plist=""
      if [ "$domain" = "system" ]; then
        plist="/Library/LaunchDaemons/$svc_id.plist"
      else
        plist="$HOME/Library/LaunchAgents/$svc_id.plist"
      fi

      case "$action" in
        status)  svc_status "$name" "$entry_json" ;;
        start)
          cleanup_service_ports "$entry_json"
          recover_launchctl_service "$domain" "$svc_id" "$sudo_prefix" || {
            $sudo_prefix launchctl enable "$target" >/dev/null 2>&1
            $sudo_prefix launchctl start "$svc_id" >/dev/null 2>&1 || \
              $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$domain")" "$plist" >/dev/null 2>&1
          }
          poll_service_ready "$name" "$entry_json" >/dev/null || {
            local _diag
            _diag=$(service_diagnostic "$entry_json")
            warn "$name — started but not running ($_diag); check 'nucleus-svc logs $name'"
            return 1
          }
          ;;
        stop)    $sudo_prefix launchctl kill SIGTERM "$target" >/dev/null 2>&1 ;;
        restart)
          # Pre-cleanup: kill any rogue process holding the service's ports.
          # This must run before launchd operations because bootout can only
          # kill processes in its tracked tree.
          cleanup_service_ports "$entry_json"
          # Three-stage restart strategy for launchctl services:
          #   1. recover_launchctl_service — handles stuck states (EX_CONFIG,
          #      "waiting", "spawn scheduled") via bootout+bootstrap.
          #   2. SIGTERM — graceful shutdown for running services.
          #   3. bootout+bootstrap — safety net that clears remaining exit
          #      codes and re-registers the service.
          #
          # Stage 3 sends SIGKILL if the process is still alive after the
          # 5s grace window.  This trade-off (forceful clear) is necessary
          # because launchd will not retry services that exited with
          # non-retryable codes.  The grace window gives well-behaved
          # processes time to shut down cleanly before the hard kill.
          #
          # After bootstrap, the service is verified running.  If launchd
          # fails to auto-start (transient bootstrap race), a start
          # fallback is attempted as a safety net.
          recover_launchctl_service "$domain" "$svc_id" "$sudo_prefix" || {
            # undoc-supp: service may not be loaded; bootout/enable on absent service exits 1.
            $sudo_prefix launchctl kill SIGTERM "$target" >/dev/null 2>&1 || true
            for _i in 1 2 3 4 5; do
              $sudo_prefix launchctl print "$target" 2>/dev/null \
                | grep -q "state = running" || break
              sleep 1
            done
            # undoc-supp: service may not be loaded; bootout/enable on absent service exits 1.
            $sudo_prefix launchctl bootout "$target" 2>/dev/null || true
            # Small delay between bootout and bootstrap to give launchd
            # time to finish cleanup and avoid a bootstrap race.
            sleep 0.5
            # undoc-supp: service may not be loaded; bootout/enable on absent service exits 1.
            $sudo_prefix launchctl bootstrap "$(launchctl_bootstrap_domain "$domain")" "$plist" 2>/dev/null || true
            # Verify the service started after bootstrap.  Poll briefly
            # and fall through to enable + start as a safety net.
            for _j in 1 2 3 4; do
              $sudo_prefix launchctl print "$target" 2>/dev/null \
                | grep -q "state = running" && break
              sleep 0.5
            done
            if ! $sudo_prefix launchctl print "$target" 2>/dev/null \
                | grep -q "state = running"; then
              # launchd may need an explicit enable+start if bootstrap
              # loaded the plist but a transient condition blocked
              # KeepAlive from auto-starting the service.
              # undoc-supp: service may not be loaded; bootout/enable on absent service exits 1.
              $sudo_prefix launchctl enable "$target" >/dev/null 2>&1 || true
              $sudo_prefix launchctl start "$svc_id" >/dev/null 2>&1 || \
                warn "$name — restart: failed to start service after reload"
            fi
          }
          # Verify the service started after all recovery stages.
          poll_service_ready "$name" "$entry_json" >/dev/null || {
            local _diag
            _diag=$(service_diagnostic "$entry_json")
            warn "$name — restarted but not running ($_diag); check 'nucleus-svc logs $name'"
            return 1
          }
          ;;
        enable)  $sudo_prefix launchctl enable "$target" >/dev/null 2>&1 ;;
        disable) $sudo_prefix launchctl disable "$target" >/dev/null 2>&1 ;;
      esac
      ;;
    systemctl)
      local scope_flag=""
      [ "$(echo "$entry_json" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"

      case "$action" in
        status)  svc_status "$name" "$entry_json" ;;
        start)
          cleanup_service_ports "$entry_json"
          systemctl $scope_flag start "$svc_id" >/dev/null 2>&1
          poll_service_ready "$name" "$entry_json" >/dev/null || {
            local _diag
            _diag=$(service_diagnostic "$entry_json")
            warn "$name — started but not running ($_diag); check 'nucleus-svc logs $name'"
            return 1
          }
          ;;
        stop)    systemctl $scope_flag stop "$svc_id" >/dev/null 2>&1 ;;
        restart)
          cleanup_service_ports "$entry_json"
          systemctl $scope_flag restart "$svc_id" >/dev/null 2>&1
          poll_service_ready "$name" "$entry_json" >/dev/null || {
            local _diag
            _diag=$(service_diagnostic "$entry_json")
            warn "$name — restarted but not running ($_diag); check 'nucleus-svc logs $name'"
            return 1
          }
          ;;
        enable)  systemctl $scope_flag enable "$svc_id" >/dev/null 2>&1 ;;
        disable) systemctl $scope_flag disable "$svc_id" >/dev/null 2>&1 ;;
      esac
      ;;
    *)
      printf '{"error":"unsupported service type: %s"}' "$svc_type"
      return 1
      ;;
  esac
}

# Action implementations

do_list() {
  local registry
  registry=$(read_registry)
  local entries
  entries=$(resolve_service_names "$registry" "${service_names[@]}")

  local has_error=false
  if [ "$json_output" = true ]; then
    printf '{"version":"1","services":{'
    local first=true
    while IFS=$'\t' read -r key display svc_json json_key; do
      if echo "$key" | grep -q '^ERROR:'; then has_error=true; continue; fi
      local status_json
      status_json=$(svc_status "$key" "$svc_json")
      $first || printf ','
      first=false
      printf '"%s":%s' "$json_key" "$status_json"
    done <<< "$entries"
    printf '}}\n'
  else
    printf '%-20s %-24s %-10s %-8s %s\n' "ID" "Name" "Status" "Running" "PID"
    printf '%.0s-' {1..80}; printf '\n'
    while IFS=$'\t' read -r key display svc_json json_key; do
      if echo "$key" | grep -q '^ERROR:'; then
        local err_name="${key#ERROR:}"
        printf '%-20s %-24s %-10s %-8s %s\n' "$err_name" "" "n/a" "-" "-"
        has_error=true
        continue
      fi
      local status_json
      status_json=$(svc_status "$key" "$svc_json")
      local status running pid exit_code
      status=$(echo "$status_json" | jq -r '.status')
      running=$(echo "$status_json" | jq -r '.running')
      pid=$(echo "$status_json" | jq -r '.pid // "-"')
      exit_code=$(echo "$status_json" | jq -r '.exitCode // ""')
      if [ -n "$exit_code" ] && [ "$exit_code" != "null" ]; then
        local exit_display="exit $exit_code"
        pid="$exit_display"
      fi
      printf '%-20s %-24s %-10s %-8s %s\n' "$json_key" "$display" "$status" "$running" "$pid"
    done <<< "$entries"
  fi
  $has_error && return 1 || return 0
}

do_status() {
  local registry
  registry=$(read_registry)
  local entries
  entries=$(resolve_service_names "$registry" "${service_names[@]}")

  if [ "$json_output" = true ]; then
    do_list
    return
  fi

  local any_error=false
  while IFS=$'\t' read -r key display svc_json json_key; do
    if echo "$key" | grep -q '^ERROR:'; then
      local err_name="${key#ERROR:}"
      warn "$err_name — $(echo "$svc_json" | jq -r '.error')"
      any_error=true
      continue
    fi
    local status_json
    status_json=$(svc_status "$key" "$svc_json")
    local status running pid exit_code
    status=$(echo "$status_json" | jq -r '.status')
    running=$(echo "$status_json" | jq -r '.running')
    pid=$(echo "$status_json" | jq -r '.pid // "-"')
    exit_code=$(echo "$status_json" | jq -r '.exitCode // ""')
    if [ -n "$exit_code" ] && [ "$exit_code" != "null" ]; then
      local exit_display="exit $exit_code"
      pid="$exit_display"
    fi
    printf '%-20s %-24s %-10s %-8s %s\n' "$json_key" "$display" "$status" "$running" "$pid"
  done <<< "$entries"
  $any_error && return 1 || return 0
}

do_action() {
  if [ "${#service_names[@]}" -eq 0 ]; then
    error "missing service name for $action"
  fi
  local registry
  registry=$(read_registry)

  local overall_exit=0
  for svc_name in "${service_names[@]}"; do
    local entry
    entry=$(echo "$registry" | jq -c --arg name "$svc_name" '.[$name] // empty')
    if [ -z "$entry" ]; then
      warn "$svc_name — service not found in registry"
      overall_exit=1
      continue
    fi

    local prefix_match
    prefix_match=$(echo "$entry" | jq -r '.platform.prefixMatch // false')
    if [ "$prefix_match" = "true" ]; then
      # For actions on prefix-match services, user must specify exact service name
      warn "$svc_name — prefix-match services (like $(echo "$entry" | jq -r '.platform.service')*) require exact name; use list or status to discover"
      overall_exit=1
      continue
    fi

    if ! svc_action "$action" "$svc_name" "$(echo "$entry" | jq '.platform')"; then
      warn "$svc_name — action $action failed"
      overall_exit=1
    fi
    if $verbose_mode && [ "$action" = "start" ] || [ "$action" = "restart" ]; then
      local _v_status
      _v_status=$(svc_status "$svc_name" "$(echo "$entry" | jq '.platform')")
      local _v_running _v_pid
      _v_running=$(echo "$_v_status" | jq -r '.running')
      _v_pid=$(echo "$_v_status" | jq -r '.pid // "-"')
      if [ "$_v_running" = "true" ]; then
        say "$action $svc_name → active (pid $_v_pid)"
      fi
    fi
  done
  return "$overall_exit"
}

# do_verify — Check all services and warn about inactive ones.
do_verify() {
  local registry
  registry=$(read_registry)
  local entries
  entries=$(resolve_service_names "$registry" "${service_names[@]}")
  local any_inactive=false

  while IFS=$'\t' read -r key display svc_json json_key; do
    if echo "$key" | grep -q '^ERROR:'; then continue; fi
    local status_json
    status_json=$(svc_status "$key" "$svc_json")
    local running
    running=$(echo "$status_json" | jq -r '.running')
    if [ "$running" != "true" ]; then
      any_inactive=true
      local diag
      diag=$(service_diagnostic "$svc_json")
      warn "$json_key — inactive ($diag); check 'nucleus-svc logs $json_key'"
    fi
  done <<< "$entries"

  if $any_inactive; then
    return 1
  fi
  say "all services active"
}

# do_endpoint — Show network endpoint(s) for a service.
#   svc endpoint <service> [<endpoint-name>]
# Reads the raw services.json (not platform-filtered) since endpoints are universal.
do_endpoint() {
  local svc_name="${service_names[0]:-}"
  local endpoint_name="${service_names[1]:-}"

  if [ -z "$svc_name" ]; then
    error "missing service name for endpoint"
  fi
  require_command jq

  local entry
  entry=$(jq -c --arg name "$svc_name" '.[$name] // empty' "$SERVICES_JSON")
  if [ -z "$entry" ]; then
    error "$svc_name — service not found in registry"
  fi

  local network
  network=$(echo "$entry" | jq -c '.network // empty')
  if [ -z "$network" ]; then
    error "$svc_name — no network endpoints defined"
  fi

  if [ -n "$endpoint_name" ]; then
    local ep
    ep=$(echo "$network" | jq -c --arg ep "$endpoint_name" '.[$ep] // empty')
    if [ -z "$ep" ]; then
      error "$svc_name — endpoint \"$endpoint_name\" not found"
    fi
    if [ "$json_output" = true ]; then
      printf '%s\n' "$ep"
    else
      echo "$ep" | jq -r '[.protocol, "://", .host, ":", (.port|tostring)] | add'
    fi
  else
    if [ "$json_output" = true ]; then
      printf '%s\n' "$network"
    else
      echo "$network" | jq -r 'to_entries[] | [.key, .value.protocol + "://" + .value.host + ":" + (.value.port|tostring)] | @tsv'
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Log subcommand helpers
# ──────────────────────────────────────────────────────────────────────────────

# Get sorted list of services defined for the current platform.
get_platform_services() {
  jq -r --arg platform "$PLATFORM" '
    to_entries[]
    | select(.key | startswith("$") | not)
    | select(.value.platforms[$platform] != null)
    | .key
  ' "$SERVICES_JSON" | sort
}

# Resolve capture mode for a service (platform-specific overrides top-level).
get_capture() {
  local svc="$1"
  jq -r --arg svc "$svc" --arg platform "$PLATFORM" '
    (.[$svc].platforms[$platform].logging.capture // .[$svc].logging.capture // "all")
  ' "$SERVICES_JSON"
}

# Get the systemd unit name for a NixOS service.
get_unit() {
  local svc="$1"
  jq -r --arg svc "$svc" '
    (.[$svc].platforms.nixos.service // "")
  ' "$SERVICES_JSON"
}

# Print all log file paths for a service (user + system dirs).
service_log_files() {
  local svc="$1"
  local user_dir system_dir
  user_dir="$(nucleus_log_dir)/$svc"
  system_dir="$(nucleus_system_log_dir)/$svc"
  for d in "$user_dir" "$system_dir"; do
    if [ -d "$d" ]; then
      find "$d" -name '*.log' -type f 2>/dev/null
    fi
  done
}

# Check if a service has any accessible log output.
service_has_logs() {
  local svc="$1"
  if [ -n "$(service_log_files "$svc")" ]; then
    return 0
  fi
  if [ "$PLATFORM" = "nixos" ]; then
    local unit
    unit="$(get_unit "$svc")"
    if [ -n "$unit" ] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$unit" -n 1 --quiet --no-pager >/dev/null 2>&1 && return 0
    fi
  fi
  return 1
}

# Show file-based logs for a service.
show_file_logs() {
  local svc="$1" lines="$2" raw="$3"
  local files
  files="$(service_log_files "$svc")"
  [ -z "$files" ] && return 1
  local sanitize_cmd="log_sanitize"
  $raw && sanitize_cmd="cat"
  # shellcheck disable=SC2086
  tail -n "$lines" $files | "$sanitize_cmd"
}

# Show journald logs for a service (NixOS only).
show_journald_logs() {
  local svc="$1" lines="$2" raw="$3" since="$4"
  local unit
  unit="$(get_unit "$svc")"
  [ -z "$unit" ] && return 1
  local since_arg=()
  [ -n "$since" ] && since_arg=(--since "$since")
  local sanitize_cmd="log_sanitize"
  $raw && sanitize_cmd="cat"
  journalctl -u "$unit" -n "$lines" --no-pager -o cat "${since_arg[@]}" | "$sanitize_cmd"
}

# ──────────────────────────────────────────────────────────────────────────────
# Log action implementations
# ──────────────────────────────────────────────────────────────────────────────

do_logs() {
  local lines=10 since="" raw=false
  local parsed_args=()
  while [ "${#service_names[@]}" -gt 0 ]; do
    case "${service_names[0]}" in
      -n|--lines) lines="${service_names[1]}"; service_names=("${service_names[@]:2}") ;;
      --since) since="${service_names[1]}"; service_names=("${service_names[@]:2}") ;;
      --raw) raw=true; service_names=("${service_names[@]:1}") ;;
      --) service_names=("${service_names[@]:1}"); break ;;
      -*) error "logs: unknown option '${service_names[0]}'" ; exit 1 ;;
      *) parsed_args+=("${service_names[0]}"); service_names=("${service_names[@]:1}") ;;
    esac
  done
  service_names=("${parsed_args[@]}")

  # No service args: list available log sources.
  if [ "${#service_names[@]}" -eq 0 ]; then
    if $json_output; then
      printf '['
      local first=true
      while IFS= read -r svc; do
        $first || printf ',',
        first=false
        printf '  "%s"' "$svc"
      done <<< "$(get_platform_services)"
      printf '\n]\n'
    else
      printf 'Available services:\n\n'
      while IFS= read -r svc; do
        local capture
        capture="$(get_capture "$svc")"
        if service_has_logs "$svc"; then
          printf '  %-25s capture=%-7s\n' "$svc" "$capture"
        else
          printf '  %-25s capture=%-7s (no logs yet)\n' "$svc" "$capture"
        fi
      done <<< "$(get_platform_services)"
    fi
    return
  fi

  for svc in "${service_names[@]}"; do
    if ! get_platform_services | grep -qx "$svc"; then
      error "logs: unknown service '$svc'"
      exit 1
    fi
    case "$PLATFORM" in
      macos)
        show_file_logs "$svc" "$lines" "$raw" || warn "$svc — no log files found"
        ;;
      nixos)
        local unit
        unit="$(get_unit "$svc")"
        if [ -n "$unit" ] && command -v journalctl >/dev/null 2>&1; then
          show_journald_logs "$svc" "$lines" "$raw" "$since" || warn "$svc — no journald logs"
        else
          show_file_logs "$svc" "$lines" "$raw" || warn "$svc — no log files found"
        fi
        ;;
    esac
  done
}

do_log_paths() {
  if [ "${#service_names[@]}" -gt 0 ]; then
    for svc in "${service_names[@]}"; do
      service_log_files "$svc"
    done
  else
    while IFS= read -r svc; do
      service_log_files "$svc"
    done <<< "$(get_platform_services)"
  fi
}

do_log_config() {
  local parsed_args=()
  while [ "${#service_names[@]}" -gt 0 ]; do
    case "${service_names[0]}" in
      --json) json_output=true; service_names=("${service_names[@]:1}") ;;
      --) service_names=("${service_names[@]:1}"); break ;;
      -*) error "log-config: unknown option '${service_names[0]}'" ; exit 1 ;;
      *) parsed_args+=("${service_names[0]}"); service_names=("${service_names[@]:1}") ;;
    esac
  done
  service_names=("${parsed_args[@]}")

  local targets=()
  if [ "${#service_names[@]}" -gt 0 ]; then
    targets=("${service_names[@]}")
  else
    while IFS= read -r svc; do targets+=("$svc"); done <<< "$(get_platform_services)"
  fi

  for svc in "${targets[@]}"; do
    local entry
    entry=$(jq -c --arg svc "$svc" --arg platform "$PLATFORM" '
      {
        capture: (.[$svc].platforms[$platform].logging.capture // .[$svc].logging.capture // "all"),
        maxSize: (.[$svc].platforms[$platform].logging.maxSize // .[$svc].logging.maxSize // 10000000), # bytes
        maxFiles: (.[$svc].platforms[$platform].logging.maxFiles // .[$svc].logging.maxFiles // 4),
        compress: (.[$svc].platforms[$platform].logging.compress // .[$svc].logging.compress // true),
        sanitize: (.[$svc].platforms[$platform].logging.sanitize // .[$svc].logging.sanitize // true),
        level: (.[$svc].platforms[$platform].logging.level // .[$svc].logging.level // null),
        eventLog: (.[$svc].platforms[$platform].logging.eventLog // .[$svc].logging.eventLog // null)
      }
    ' "$SERVICES_JSON")
    if $json_output; then
      printf '{"%s":%s}\n' "$svc" "$entry"
    else
      printf '%s:\n' "$svc"
      echo "$entry" | jq -r '
        to_entries[]
        | select(.value != null)
        | "  \(.key): \(.value)"
      '
    fi
  done
}

# Main

json_output=false
verbose_mode=false
action=""
service_names=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) json_output=true; shift ;;
    --verbose) verbose_mode=true; shift ;;
    endpoint|logs|log-paths|log-config|verify)
      action="$1"; shift
      service_names=("$@")
      break
      ;;
    list|status|start|stop|restart|enable|disable)
      action="$1"; shift
      service_names=("$@")
      break
      ;;
    *) error "unsupported argument '$1'" ; usage >&2 ; exit 1 ;;
  esac
done

# Filter --json and --verbose from service_names (can appear before or after action)
filtered_service_names=()
for arg in "${service_names[@]}"; do
  if [ "$arg" = "--json" ]; then
    json_output=true
  elif [ "$arg" = "--verbose" ]; then
    verbose_mode=true
  else
    filtered_service_names+=("$arg")
  fi
done
service_names=("${filtered_service_names[@]}")

[ -z "$action" ] && { error "missing action (list, status, start, stop, restart, enable, disable, verify, endpoint, logs, log-paths, log-config)" ; usage >&2 ; exit 1; }

case "$action" in
  list|status|logs) "do_$action" ;;
  log-paths) do_log_paths ;;
  log-config) do_log_config ;;
  verify|endpoint) "do_$action" ;;
  start|stop|restart|enable|disable) do_action ;;
esac
