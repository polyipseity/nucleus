# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "app-registry" "App auto-start registry validation" run_app_registry

run_app_registry() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _app_errors=0
  local _app_json="src/modules/apps.json"

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

    # enabled / disableNative must be booleans; kind must be in the enum.
    while IFS=$'\t' read -r _name _host _enabled _disable_native _kind; do
      case "$_enabled" in
      true | false) ;;
      *)
        error "apps.json: '$_name' host '$_host' enabled must be boolean (got '$_enabled')"
        _app_errors=$((_app_errors + 1))
        ;;
      esac
      case "$_disable_native" in
      true | false) ;;
      *)
        error "apps.json: '$_name' host '$_host' disableNative must be boolean (got '$_disable_native')"
        _app_errors=$((_app_errors + 1))
        ;;
      esac
      case "$_kind" in
      login-item | launchagent | xdg-desktop | run-key | startup-folder | system-extension) ;;
      omitted | "missing") ;;
      *)
        error "apps.json: '$_name' host '$_host' has invalid kind '$_kind'"
        _app_errors=$((_app_errors + 1))
        ;;
      esac
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.hosts // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.enabled // "missing" | tostring),
        (.value.disableNative // "missing" | tostring),
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
