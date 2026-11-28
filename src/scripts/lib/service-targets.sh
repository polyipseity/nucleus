# shellcheck shell=bash
# Live service targets from the registry. Defines functions and constants only.
# Each host entry is either a registry key or one concrete prefix-match instance.

# WHY: svc and apply need one list of registry types they understand. HKCU Run
# is a real carrier, but user activation owns it, not a supervisor probe.
service_type_supported() {
  case "$1" in
  macos-launchctl | nixos-systemctl | windows-native | windows-schtask | windows-user-autostart)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# WHY: host filtering, omitted exclusion, and type validation stay here so svc
# and apply cannot disagree about which registry rows exist for a host.
service_registry_for_host() {
  local registry="$1" host="$2" filtered svc_type

  if [ ! -f "$registry" ]; then
    printf 'services registry not found at %s\n' "$registry" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to read %s\n' "$registry" >&2
    return 1
  fi

  filtered="$(jq -c --arg host "$host" '
    to_entries | map(
      select(.value | type == "object")
      | select(.value.hosts | has($host))
      | select(.value.hosts[$host].type != "omitted")
      | {key: .key, value: {displayName: .value.displayName, description: .value.description, network: .value.network, hostEntry: .value.hosts[$host]}}
    ) | from_entries
  ' "$registry")" || return 1

  while IFS= read -r svc_type; do
    if ! service_type_supported "$svc_type"; then
      printf 'unsupported service type %s in %s\n' "$svc_type" "$registry" >&2
      return 1
    fi
  done < <(printf '%s\n' "$filtered" | jq -r 'to_entries[].value.hostEntry.type')

  printf '%s\n' "$filtered"
}

# Loads the prefix-match helpers only when a prefix row is expanded, so callers
# that only need non-prefix targets do not depend on a service manager.
service_targets_load_instance_lib() {
  local lib_dir
  lib_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=svc-instances.sh
  . "$lib_dir/svc-instances.sh"
}

# Prints the concrete ids a host entry acts on: its registry key, or one id per
# live prefix-match instance. Configured-only instances are not loaded rows.
service_live_instances() {
  local key="$1" plat_json="$2" instances instance

  if [ "$(printf '%s' "$plat_json" | jq -r '.prefixMatch // false')" != "true" ]; then
    printf '%s\n' "$key"
    return 0
  fi

  service_targets_load_instance_lib
  instances=$(svc_prefix_instances "$plat_json")
  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    printf '%s\n' "$instance"
  done <<<"$instances"
}

service_targets_for_host() {
  local registry="$1" host="$2" filtered key plat_json instance

  filtered="$(service_registry_for_host "$registry" "$host")" || return 1
  while IFS=$'\t' read -r key plat_json; do
    [ -n "$key" ] || continue
    while IFS= read -r instance; do
      [ -n "$instance" ] || continue
      printf '%s\n' "$instance"
    done < <(service_live_instances "$key" "$plat_json")
  done < <(printf '%s\n' "$filtered" |
    jq -r 'to_entries[] | [.key, (.value.hostEntry | tojson)] | @tsv')
}
