# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "app-registry" "App auto-start registry validation" run_app_registry

# _kind_in_enum <kind> <array-name> — true when the named array holds <kind>.
_kind_in_enum() {
  local -n _haystack="$2"
  local _item
  for _item in "${_haystack[@]}"; do
    if [ "$_item" = "$1" ]; then return 0; fi
  done
  return 1
}

# _platform_for_kind <kind> — print the platform a platform-prefixed kind
# belongs to, or nothing when the kind is platform-neutral.
_platform_for_kind() {
  case "$1" in
  macos-*) echo "macOS" ;;
  nixos-*) echo "NixOS" ;;
  windows-*) echo "Windows" ;;
  esac
}

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

  local -a _valid_icon_kinds=()
  local _valid_icon_kind
  while IFS= read -r _valid_icon_kind; do
    _valid_icon_kinds+=("$_valid_icon_kind")
  done < <(jq -r '.definitions.statusIconKind.enum[]' "$_app_schema")

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

    # autostartEnabled must be boolean, and kind must be in the schema enum;
    # a platform-prefixed kind must match its host platform.
    while IFS=$'\t' read -r _name _host _type _platform _enabled _kind _has_approval; do
      # Omitted hosts carry no runtime fields; the first loop already validated
      # their justification. Skip boolean/kind checks for them.
      [ "$_type" = "omitted" ] && continue
      # autostartEnabled is required for every kind we launch and forbidden for
      # 'manual' — nothing is launched, so a toggle there would be a lie.
      if [ "$_kind" = "manual" ]; then
        if [ "$_enabled" != "missing" ]; then
          error "apps.json: '$_name' host '$_host' kind 'manual' must not set autostartEnabled"
          _app_errors=$((_app_errors + 1))
        fi
      else
        case "$_enabled" in
        true | false) ;;
        *)
          error "apps.json: '$_name' host '$_host' autostartEnabled must be boolean (got '$_enabled')"
          _app_errors=$((_app_errors + 1))
          ;;
        esac
      fi
      if [ "$_kind" != "missing" ] && ! _kind_in_enum "$_kind" _valid_kinds; then
        error "apps.json: '$_name' host '$_host' has invalid kind '$_kind'"
        _app_errors=$((_app_errors + 1))
      fi

      # A platform-prefixed kind belongs to that platform alone. Deriving the
      # platform from the prefix is what keeps the naming honest: a macOS-only
      # mechanism can no longer be declared on Linux or Windows.
      local _kind_platform
      _kind_platform=$(_platform_for_kind "$_kind")
      if [ -n "$_kind_platform" ] && [ "$_kind_platform" != "$_platform" ]; then
        error "apps.json: '$_name' host '$_host' kind '$_kind' is $_kind_platform-only but the host platform is '$_platform'"
        _app_errors=$((_app_errors + 1))
      fi

      # Kinds no script can converge still need approvalInstructions: that text
      # is the only guidance the report prints.
      case "$_kind" in
      macos-system-extension | manual)
        if [ "$_has_approval" != "true" ]; then
          error "apps.json: '$_name' host '$_host' kind '$_kind' requires approvalInstructions"
          _app_errors=$((_app_errors + 1))
        fi
        ;;
      esac
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.hosts // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.type // "missing"),
        (.value.platform // "missing"),
        (if (.value | has("autostartEnabled")) then (.value.autostartEnabled | tostring) else "missing" end),
        (.value.kind // "missing"),
        (if (.value | has("approvalInstructions")) and (.value.approvalInstructions | type == "string") and (.value.approvalInstructions | length > 0) then "true" else "false" end)
      ] | @tsv' "$_app_json")

    # The status-icon kinds follow the same two rules as the auto-start kinds:
    # they must come from the schema enum, and a platform prefix must match.
    while IFS=$'\t' read -r _name _host _platform _icon_kind; do
      if ! _kind_in_enum "$_icon_kind" _valid_icon_kinds; then
        error "apps.json: '$_name' host '$_host' has invalid statusIcon kind '$_icon_kind'"
        _app_errors=$((_app_errors + 1))
      fi
      local _icon_platform
      _icon_platform=$(_platform_for_kind "$_icon_kind")
      if [ -n "$_icon_platform" ] && [ "$_icon_platform" != "$_platform" ]; then
        error "apps.json: '$_name' host '$_host' statusIcon kind '$_icon_kind' is $_icon_platform-only but the host platform is '$_platform'"
        _app_errors=$((_app_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.hosts // {}) | to_entries[] |
      select(.value.statusIcon != null) |
      [
        $name,
        .key,
        (.value.platform // "missing"),
        (.value.statusIcon.kind // "missing")
      ] | @tsv' "$_app_json")
  fi

  if [ "$_app_errors" -gt 0 ]; then
    error "app registry validation failed with $_app_errors error(s)"
    return 1
  fi
  say "app registry validation passed."
  return 0
}
