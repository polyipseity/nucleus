# shellcheck shell=bash
# src/scripts/lib/svc-instances.sh — Instance resolution for prefix-match
# services (services.json host entries with prefixMatch: true).
#
# A prefix-match entry (e.g. cloud-drive) stands in for one runtime service per
# configured instance; the concrete ids only exist at runtime. This library is
# the single implementation of that mapping, shared by scripts/svc.sh (list,
# status, actions, verify, logs) and src/scripts/services/service-watchdog.sh.
#
# Functions:
#   svc_instance_suffix       <entryJson> <instanceId>
#   svc_instance_entry        <entryJson> <instanceId>
#   svc_prefix_instances      <entryJson>
#   svc_instance_log_dirs     <entryJson> <logRoot> <systemLogRoot> <instanceId>
#   svc_configured_instance_ids <entryJson> <mountsJson>
#   svc_configured_mounts     <repoRoot> <host> [username]
#   svc_notloaded_transition  <key> <stateDir>
#   svc_notloaded_clear       <key> <stateDir>
#
# Requirements: jq; launchctl (macOS) or systemctl (NixOS) for live enumeration.
# Pure function definitions only — no top-level side effects on import.

# svc_instance_suffix — Instance id minus the entry's declared service prefix.
# Args: $1 — host entry JSON; $2 — concrete instance id.
# Output: the per-instance suffix (e.g. "iCloud" for local.cloud-mount.iCloud,
# cloud-mount-iCloud.service, or \NucleusCloudMount\NucleusCloudMount-iCloud).
# WHY: log directories are named from the mount id, not from the full runtime
# id, so the registry needs a deterministic way to build the directory name.
svc_instance_suffix() {
  local entry="$1" instance="$2" base prefix

  base="${instance##*[/\\]}"
  prefix="$(printf '%s' "$entry" | jq -r '.service // ""')"
  if [ -n "$prefix" ] && [ "${base#"$prefix"}" != "$base" ]; then
    base="${base#"$prefix"}"
  fi
  printf '%s\n' "${base%.service}"
}

# svc_instance_entry — Concrete host entry for one instance.
# Args: $1 — host entry JSON; $2 — concrete instance id.
# Output: host entry JSON with the instance id as its runtime identity and no
# prefixMatch flag (so probe/action helpers treat it as an ordinary service).
svc_instance_entry() {
  local entry="$1" instance="$2"

  printf '%s' "$entry" | jq -c --arg id "$instance" '
    (if .type == "schtask" then . + {taskPath: $id} else . + {service: $id} end)
    | del(.prefixMatch)
  '
}

# svc_prefix_instances — Live instances of a prefix-match entry.
# Args: $1 — host entry JSON.
# Output: concrete instance ids, one per line, sorted; empty when none exist.
# WHY: prefix match is a literal string-prefix test (index()==1), never a
# regex — registry prefixes contain "." and would otherwise match unrelated ids.
svc_prefix_instances() {
  local entry="$1" svc_type prefix matches

  svc_type="$(printf '%s' "$entry" | jq -r '.type')"
  prefix="$(printf '%s' "$entry" | jq -r '.service // ""')"
  [ -n "$prefix" ] || return 0

  case "$svc_type" in
  launchctl)
    local scope sudo_prefix="" uid
    scope="$(printf '%s' "$entry" | jq -r '.scope // "system"')"
    uid="${REAL_USER_UID:-$(id -u)}"
    [ "$scope" = "system" ] && sudo_prefix="sudo"
    # check-suppress:suppression_doc: no matching instances is an expected empty result, not an error.
    if [ "$scope" = "user" ] && [ "$(id -u)" -eq 0 ]; then
      matches="$(launchctl asuser "$uid" launchctl list 2>/dev/null | awk -v p="$prefix" 'index($3, p) == 1 { print $3 }' || true)" # check-suppress:suppression_doc: no matching instances is an expected empty result, not an error.
    else
      matches="$($sudo_prefix launchctl list 2>/dev/null | awk -v p="$prefix" 'index($3, p) == 1 { print $3 }' || true)" # check-suppress:suppression_doc: no matching instances is an expected empty result, not an error.
    fi
    ;;
  systemctl)
    local scope_flag=""
    [ "$(printf '%s' "$entry" | jq -r '.scope // "system"')" = "user" ] && scope_flag="--user"
    # check-suppress:suppression_doc: no matching units is an expected empty result, not an error.
    matches="$(systemctl $scope_flag --no-pager list-units --all "$prefix*" --no-legend 2>/dev/null | awk -v p="$prefix" 'index($1, p) == 1 { print $1 }' || true)" # check-suppress:suppression_doc: no matching units is an expected empty result, not an error.
    ;;
  *)
    return 0
    ;;
  esac

  [ -n "$matches" ] || return 0
  printf '%s\n' "$matches" | LC_ALL=C sort -u
}

# svc_instance_log_dirs — Per-instance log directories for one instance.
# Args: $1 — host entry JSON; $2 — user log root; $3 — system log root;
#       $4 — concrete instance id.
# Output: absolute directories, one per line; nothing when the entry declares
# no per-instance dirs. Templates carry an <instance> token that expands to the
# instance suffix; dirs are created by the service itself, never by apply.
svc_instance_log_dirs() {
  local entry="$1" log_root="$2" system_root="$3" instance="$4"
  local suffix subdir

  suffix="$(svc_instance_suffix "$entry" "$instance")"
  while IFS= read -r subdir; do
    [ -n "$subdir" ] && printf '%s\n' "$log_root/${subdir//<instance>/$suffix}"
  done <<<"$(printf '%s' "$entry" | jq -r '.logging.instanceDirs.user[]? // empty')"

  while IFS= read -r subdir; do
    [ -n "$subdir" ] && printf '%s\n' "$system_root/${subdir//<instance>/$suffix}"
  done <<<"$(printf '%s' "$entry" | jq -r '.logging.instanceDirs.system[]? // empty')"
}

# svc_configured_instance_ids — Expected instance ids for a prefix-match entry.
# Args: $1 — host entry JSON; $2 — mounts array JSON (user registry cloud-drives).
# Output: instance ids apply is expected to create, one per line, sorted.
# WHY: ids are derived from the registry, not stored, so a single source of
# truth (the mount manifest) drives both provisioning and discovery. `enable`
# defaults to true (cloud-drives.nix mountSubmodule) and a mount without a
# configured remote is declared but never instantiated.
svc_configured_instance_ids() {
  local entry="$1" mounts="$2" svc_type prefix task_path ids

  svc_type="$(printf '%s' "$entry" | jq -r '.type')"
  prefix="$(printf '%s' "$entry" | jq -r '.service // ""')"
  task_path="$(printf '%s' "$entry" | jq -r '.taskPath // ""')"

  ids="$(printf '%s' "$mounts" | jq -r '
    .[]? | select((.enable // true) and (.remoteName != null)) | .id
  ')"
  [ -n "$ids" ] || return 0

  case "$svc_type" in
  launchctl)
    while IFS= read -r id; do printf '%s%s\n' "$prefix" "$id"; done <<<"$ids"
    ;;
  systemctl)
    while IFS= read -r id; do printf '%s%s.service\n' "$prefix" "$id"; done <<<"$ids"
    ;;
  schtask)
    task_path="${task_path%\\}"
    while IFS= read -r id; do printf '%s\\%s%s\n' "$task_path" "$prefix" "$id"; done <<<"$ids"
    ;;
  esac
}

# svc_configured_mounts — Mounts the invoking user's registry declares.
# Args: $1 — repo root; $2 — host key (MacBook|NixOS|Windows); $3 — username
#       (default: SUDO_USER, else id -un).
# Output: the merged cloud-drives mounts array as JSON.
# WHY: the registry is the same input the cloud-drives Nix module consumes, so
# discovery cannot drift from provisioning. Scope is the invoking user — a user
# with no registry entry simply declares no mounts.
svc_configured_mounts() {
  local repo_root="$1" host="$2" username="${3:-${SUDO_USER:-$(id -un)}}" lib_dir

  lib_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  "$lib_dir/load-user-registry.sh" --host "$host" --repo-root "$repo_root" |
    jq -c --arg user "$username" '.[$user].cloudDrives.mounts // []'
}

# svc_notloaded_transition — First-occurrence marker for a not-loaded instance.
# Args: $1 — instance key; $2 — state directory.
# Output: "first" the first time a key is reported, "repeat" afterwards.
# WHY: the watchdog ticks every 300s; logging the same not-loaded instance on
# every tick would flood the log, so only transitions are reported.
svc_notloaded_transition() {
  local key="$1" state_dir="$2" marker

  marker="$state_dir/$key.notloaded"
  if [ -e "$marker" ]; then
    printf 'repeat\n'
    return 0
  fi
  mkdir -p "$state_dir"
  : >"$marker"
  printf 'first\n'
}

# svc_notloaded_clear — Drop the not-loaded marker once an instance is live.
# Args: $1 — instance key; $2 — state directory.
svc_notloaded_clear() {
  local marker="$2/$1.notloaded"

  [ -e "$marker" ] || return 0
  rm -f "$marker"
}
