# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "service-registry" 14 "Service registry validation" run_14_service_registry

run_14_service_registry() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _svc_errors=0
  local _svc_json="src/modules/services.json"
  local _users_root="src/users"
  local _svc_names

  if [ ! -f "$_svc_json" ]; then
    error "services.json not found at $_svc_json"
    _svc_errors=$((_svc_errors + 1))
  else
    # Check each entry has displayName and hosts
    while IFS=$'\t' read -r _name _has_display _has_hosts _host_count; do
      if [ "$_has_display" != "true" ]; then
        error "services.json: '$_name' missing displayName"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_has_hosts" != "true" ]; then
        error "services.json: '$_name' missing hosts"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_host_count" -lt 1 ]; then
        error "services.json: '$_name' has no host entries"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      [
        .key,
        (.value | has("displayName") and (.displayName | type == "string") and (.displayName | length > 0) | tostring),
        (.value | has("hosts") and (.hosts | type == "object") | tostring),
        (.value.hosts | if type == "object" then (keys | length) else 0 end | tostring)
      ] | @tsv' "$_svc_json")

    # Validate each host entry has valid type, platform ref, and required fields
    while IFS=$'\t' read -r _name _host _type _platform _has_required; do
      case "$_type" in
        launchctl|systemctl|native|schtask|omitted) ;;
        *)
          error "services.json: '$_name' host '$_host' has invalid type '$_type'"
          _svc_errors=$((_svc_errors + 1))
          ;;
      esac
      case "$_platform" in
        macOS|NixOS|Windows) ;;
        *)
          error "services.json: '$_name' host '$_host' has invalid platform '$_platform'"
          _svc_errors=$((_svc_errors + 1))
          ;;
      esac
      if [ "$_has_required" != "true" ]; then
        error "services.json: '$_name' host '$_host' missing required fields for type '$_type'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.hosts // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.type // "missing"),
        (.value.platform // "missing"),
        (
          if .value.type == "launchctl" then (.value.service | type == "string" and length > 0)
          elif .value.type == "systemctl" then (.value.service | type == "string" and length > 0)
          elif .value.type == "native" then (.value.service | type == "string" and length > 0)
          elif .value.type == "schtask" then (.value.taskPath | type == "string" and length > 0)
          elif .value.type == "omitted" then (.value.justification | type == "string" and length > 0)
          else false
          end | tostring
        )
      ] | @tsv' "$_svc_json")
  fi

  # Validate user-scoped host entries have justification.
  while IFS=$'\t' read -r _name _host _domain_scope _value; do
    if [ "$_domain_scope" = "user" ] && { [ "$_value" = "null" ] || [ -z "$_value" ]; }; then
      error "services.json: '$_name' host '$_host' is user-scoped but missing justification"
      _svc_errors=$((_svc_errors + 1))
    fi
  done < <(jq -r '
    to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
    .key as $name |
    (.value.hosts // {}) | to_entries[] |
    [
      $name,
      .key,
      (.value.domain // .value.scope // ""),
      (.value.justification | tostring)
    ] | @tsv' "$_svc_json")

  # Validate service names in per-user services.json files exist in services.json.
  _svc_names=$(jq -r 'to_entries[].key' "$_svc_json")
  if [ -d "$_users_root" ]; then
    for _user_services in "$_users_root"/*/services.json; do
      [ -f "$_user_services" ] || continue
      _username="$(basename "$(dirname "$_user_services")")"
      case "$_username" in
        default) continue ;;
      esac
      while IFS=$'\t' read -r _svc_name; do
        if ! echo "$_svc_names" | grep -qxF "$_svc_name"; then
          error "$_user_services: user '$_username' references unknown service '$_svc_name'"
          _svc_errors=$((_svc_errors + 1))
        fi
      done < <(jq -r '
        to_entries[] | select(.key | startswith("$") | not) |
        select(.value.enable != null) |
        .key' "$_user_services")
    done
  fi

  if [ "$_svc_errors" -gt 0 ]; then
    error "services.json validation failed with $_svc_errors error(s)"
    return 1
  fi
  say "services.json validation passed"
  return 0
}
