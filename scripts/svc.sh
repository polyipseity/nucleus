#!/usr/bin/env bash
# svc.sh — Unified service management for POSIX hosts (macOS + NixOS).
#
# Provides a uniform CLI for listing, starting, stopping, restarting,
# enabling, and disabling services across macOS (launchctl) and NixOS (systemctl).
# Services are defined in src/modules/services.json (the canonical registry).
#
# Arguments:
#   list                              List all known services with status.
#   status [service...]               Show status of all (or specific) services.
#   start <service>                   Start a service.
#   stop <service>                    Stop a service.
#   restart <service>                 Restart a service.
#   enable <service>                  Enable auto-start.
#   disable <service>                 Disable auto-start.
#   endpoint <service> [<name>]       Show network endpoint(s) for a service.
#
# Options:
#   --json        Machine-readable JSON output.
#   -h|--help     Show usage.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  usage_std "$(basename "$0")" "list|status|start|stop|restart|enable|disable|endpoint [service...] [options]"
  cat <<'EOF'
  list                              List all known services with status.
  status [service...]               Show status of specified services (all if omitted).
  start <service>                   Start a service.
  stop <service>                    Stop a service.
  restart <service>                 Restart a service.
  enable <service>                  Enable auto-start.
  disable <service>                 Disable auto-start.
  endpoint <service> [<name>]       Show network endpoint(s) for a service.
  --json                            Machine-readable JSON output.
  -h|--help                         Show usage.
EOF
}

REPO_ROOT="$(resolve_nucleus_root)"
SERVICES_JSON="$REPO_ROOT/src/modules/services.json"
HOST="$(resolve_nucleus_host)"

# Map resolve_nucleus_host output to services.json platform key
case "$HOST" in
  MacBook) PLATFORM="macos" ;;
  NixOS)   PLATFORM="nixos" ;;
  *)       printf '%s\n' "svc: unsupported host '$HOST'" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# read_registry — Parse services.json and return JSON filtered to current platform.
read_registry() {
  if [ ! -f "$SERVICES_JSON" ]; then
    printf '%s\n' "svc: services registry not found at $SERVICES_JSON" >&2
    exit 1
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
      list_line=$($domain_flag launchctl list 2>/dev/null | awk -v label="$svc_id" 'NR>1 && $3==label { print $1, $2 }' || true)
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
      printf '{"status":"%s","running":%s,"enabled":%s,"pid":%s}' \
        "$( [ "$running" = true ] && echo "active" || echo "inactive" )" \
        "$running" "$enabled" "${pid:-null}"
      ;;
    systemctl)
      local scope_flag=""
      [ "$(echo "$entry_json" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"

      local is_active is_enabled
      is_active=$(systemctl $scope_flag is-active "$svc_id" 2>/dev/null || echo "inactive")
      is_enabled=$(systemctl $scope_flag is-enabled "$svc_id" 2>/dev/null || echo "disabled")

      local running=true
      [ "$is_active" != "active" ] && running=false
      local enabled_bool=true
      [ "$is_enabled" != "enabled" ] && enabled_bool=false

      local pid=""
      if [ "$running" = true ]; then
        pid=$(systemctl $scope_flag show -p MainPID "$svc_id" 2>/dev/null | sed 's/MainPID=//' || true)
        [ -z "$pid" ] || [ "$pid" = "0" ] && pid=""
      fi
      printf '{"status":"%s","running":%s,"enabled":%s,"pid":%s}' "$is_active" "$running" "$enabled_bool" "${pid:-null}"
      ;;
    *)
      printf '{"status":"unknown","running":false,"enabled":false,"pid":null}'
      ;;
  esac
}

# launchctl_target — Build a macOS launchctl service target specifier.
# macOS 25+ requires gui/<uid>/<service> for user domain and
# system/<service> for system domain. Older macOS accepted bare service IDs.
launchctl_target() {
  local domain="$1"
  local service="$2"
  if [ "$domain" = "system" ]; then
    printf 'system/%s' "$service"
  else
    printf 'gui/%s/%s' "$(id -u)" "$service"
  fi
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

      case "$action" in
        status)  svc_status "$name" "$entry_json" ;;
        start)   $sudo_prefix launchctl kickstart -p "$target" >/dev/null 2>&1 || $sudo_prefix launchctl start "$svc_id" >/dev/null 2>&1 ;;
        stop)    $sudo_prefix launchctl kill SIGTERM "$target" >/dev/null 2>&1 ;;
        restart) $sudo_prefix launchctl kickstart -k -p "$target" >/dev/null 2>&1 ;;
        enable)  $sudo_prefix launchctl enable "$target" >/dev/null 2>&1 ;;
        disable) $sudo_prefix launchctl disable "$target" >/dev/null 2>&1 ;;
      esac
      ;;
    systemctl)
      local scope_flag=""
      [ "$(echo "$entry_json" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"

      case "$action" in
        status)  svc_status "$name" "$entry_json" ;;
        start)   systemctl $scope_flag start "$svc_id" >/dev/null 2>&1 ;;
        stop)    systemctl $scope_flag stop "$svc_id" >/dev/null 2>&1 ;;
        restart) systemctl $scope_flag restart "$svc_id" >/dev/null 2>&1 ;;
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

# ---------------------------------------------------------------------------
# Action implementations
# ---------------------------------------------------------------------------

do_list() {
  local registry
  registry=$(read_registry)
  local entries
  entries=$(resolve_service_names "$registry" "${service_names[@]}")

  local has_error=false
  if [ "$json_output" = true ]; then
    printf '{"svc_version":"1","services":{'
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
    printf '%-24s %-10s %-8s %s\n' "Service" "Status" "Running" "PID"
    printf '%.0s-' {1..60}; printf '\n'
    while IFS=$'\t' read -r key display svc_json json_key; do
      if echo "$key" | grep -q '^ERROR:'; then
        local err_name="${key#ERROR:}"
        printf '%-24s %-10s %-8s %s\n' "$err_name" "n/a" "-" "-"
        has_error=true
        continue
      fi
      local status_json
      status_json=$(svc_status "$key" "$svc_json")
      local status running pid
      status=$(echo "$status_json" | jq -r '.status')
      running=$(echo "$status_json" | jq -r '.running')
      pid=$(echo "$status_json" | jq -r '.pid // "-"')
      printf '%-24s %-10s %-8s %s\n' "$display" "$status" "$running" "$pid"
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
      printf 'svc: %s — %s\n' "$err_name" "$(echo "$svc_json" | jq -r '.error')" >&2
      any_error=true
      continue
    fi
    local status_json
    status_json=$(svc_status "$key" "$svc_json")
    local status running pid
    status=$(echo "$status_json" | jq -r '.status')
    running=$(echo "$status_json" | jq -r '.running')
    pid=$(echo "$status_json" | jq -r '.pid // "-"')
    printf '%-24s %-10s %-8s %s\n' "$display" "$status" "$running" "$pid"
  done <<< "$entries"
  $any_error && return 1 || return 0
}

do_action() {
  if [ "${#service_names[@]}" -eq 0 ]; then
    printf 'svc: missing service name for %s\n' "$action" >&2
    exit 1
  fi
  local registry
  registry=$(read_registry)

  local overall_exit=0
  for svc_name in "${service_names[@]}"; do
    local entry
    entry=$(echo "$registry" | jq -c --arg name "$svc_name" '.[$name] // empty')
    if [ -z "$entry" ]; then
      printf 'svc: %s — service not found in registry\n' "$svc_name" >&2
      overall_exit=1
      continue
    fi

    local prefix_match
    prefix_match=$(echo "$entry" | jq -r '.platform.prefixMatch // false')
    if [ "$prefix_match" = "true" ]; then
      # For actions on prefix-match services, user must specify exact service name
      printf 'svc: %s — prefix-match services (like %s*) require exact name; use list or status to discover\n' "$svc_name" "$(echo "$entry" | jq -r '.platform.service')" >&2
      overall_exit=1
      continue
    fi

    if ! svc_action "$action" "$svc_name" "$(echo "$entry" | jq '.platform')"; then
      printf 'svc: %s — action %s failed\n' "$svc_name" "$action" >&2
      overall_exit=1
    fi
  done
  return "$overall_exit"
}

# do_endpoint — Show network endpoint(s) for a service.
#   svc endpoint <service> [<endpoint-name>]
# Reads the raw services.json (not platform-filtered) since endpoints are universal.
do_endpoint() {
  local svc_name="${service_names[0]:-}"
  local endpoint_name="${service_names[1]:-}"

  if [ -z "$svc_name" ]; then
    printf '%s\n' "svc: missing service name for endpoint" >&2
    exit 1
  fi
  require_command jq

  local entry
  entry=$(jq -c --arg name "$svc_name" '.[$name] // empty' "$SERVICES_JSON")
  if [ -z "$entry" ]; then
    printf 'svc: %s — service not found in registry\n' "$svc_name" >&2
    exit 1
  fi

  local network
  network=$(echo "$entry" | jq -c '.network // empty')
  if [ -z "$network" ]; then
    printf 'svc: %s — no network endpoints defined\n' "$svc_name" >&2
    exit 1
  fi

  if [ -n "$endpoint_name" ]; then
    local ep
    ep=$(echo "$network" | jq -c --arg ep "$endpoint_name" '.[$ep] // empty')
    if [ -z "$ep" ]; then
      printf 'svc: %s — endpoint "%s" not found\n' "$svc_name" "$endpoint_name" >&2
      exit 1
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

json_output=false
action=""
service_names=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) json_output=true; shift ;;
    endpoint)
      action="$1"; shift
      service_names=("$@")
      break
      ;;
    list|status|start|stop|restart|enable|disable)
      action="$1"; shift
      service_names=("$@")
      break
      ;;
    *) printf '%s\n' "svc: unsupported argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# Filter --json from service_names (can appear before or after action)
filtered_service_names=()
for arg in "${service_names[@]}"; do
  if [ "$arg" = "--json" ]; then
    json_output=true
  else
    filtered_service_names+=("$arg")
  fi
done
service_names=("${filtered_service_names[@]}")

[ -z "$action" ] && { printf '%s\n' "svc: missing action (list, status, start, stop, restart, enable, disable, endpoint)" >&2; usage >&2; exit 1; }

case "$action" in
  list)   do_list ;;
  status) do_status ;;
  endpoint) do_endpoint ;;
  start|stop|restart|enable|disable) do_action ;;
esac
