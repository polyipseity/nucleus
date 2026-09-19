# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "app-registry" "App auto-start registry validation" run_app_registry

run_app_registry() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _app_errors=0
  local _app_json="src/modules/apps.json"
  local _app_schema="src/modules/apps.schema.json"

  # The valid kinds are read from the schema enum. A second hardcoded list is
  # what let step 15 reject a kind the schema already accepted.
  local -a _valid_kinds=()
  local _valid_kind
  while IFS= read -r _valid_kind; do
    _valid_kinds+=("$_valid_kind")
  done < <(jq -r '.definitions.autostartKind.enum[]' "$_app_schema")

  if [ ! -f "$_app_json" ]; then
    error "apps.json not found at $_app_json"
    _app_errors=$((_app_errors + 1))
  else
    # Every app must declare all three hosts or use omitted + justification.
    while IFS=$'\t' read -r _name _host _type _has_justification; do
      if [ "$_type" = "omitted" ] && [ "$_has_justification" != "true" ]; then
        error "apps.json: '$_name' host '$_host' is omitted but missing justification"
        _app_errors=$((_app_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.hosts // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.type // "missing"),
        (if .value.type == "omitted" then (.value.justification | type == "string" and length > 0) else true end | tostring)
      ] | @tsv' "$_app_json")

    # autostartEnabled / autostartDisableNative must be booleans; kind must be in the schema enum.
    while IFS=$'\t' read -r _name _host _type _enabled _disable_native _kind; do
      # Omitted hosts carry no runtime fields; the first loop already validated
      # their justification. Skip boolean/kind checks for them.
      [ "$_type" = "omitted" ] && continue
      case "$_enabled" in
      true | false) ;;
      *)
        error "apps.json: '$_name' host '$_host' autostartEnabled must be boolean (got '$_enabled')"
        _app_errors=$((_app_errors + 1))
        ;;
      esac
      case "$_disable_native" in
      true | false) ;;
      *)
        error "apps.json: '$_name' host '$_host' autostartDisableNative must be boolean (got '$_disable_native')"
        _app_errors=$((_app_errors + 1))
        ;;
      esac
      if [ "$_kind" != "missing" ]; then
        local _kind_valid=false
        local _valid
        for _valid in "${_valid_kinds[@]}"; do
          if [ "$_valid" = "$_kind" ]; then
            _kind_valid=true
            break
          fi
        done
        if [ "$_kind_valid" != true ]; then
          error "apps.json: '$_name' host '$_host' has invalid kind '$_kind'"
          _app_errors=$((_app_errors + 1))
        fi
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.hosts // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.type // "missing"),
        (if (.value | has("autostartEnabled")) then (.value.autostartEnabled | tostring) else "missing" end),
        (if (.value | has("autostartDisableNative")) then (.value.autostartDisableNative | tostring) else "missing" end),
        (.value.kind // "missing")
      ] | @tsv' "$_app_json")
  fi

  if [ "$_app_errors" -gt 0 ]; then
    error "app registry validation failed with $_app_errors error(s)"
    return 1
  fi
  say "app registry validation passed."
  return 0
}
