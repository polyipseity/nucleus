# shellcheck shell=bash
# Instance resolution for prefix-match services (services.json host entries with
# prefixMatch: true). Needs jq plus launchctl (macOS) or systemctl (NixOS).
# Function definitions only, no top-level side effects.

# WHY: log directories are named from the mount id, not the full runtime id, so
# the registry needs a deterministic way to build the directory name.
svc_instance_suffix() {
  local entry="$1" instance="$2" base prefix

  base="${instance##*[/\\]}"
  prefix="$(printf '%s' "$entry" | jq -r '.service // ""')"
  if [ -n "$prefix" ] && [ "${base#"$prefix"}" != "$base" ]; then
    base="${base#"$prefix"}"
  fi
  printf '%s\n' "${base%.service}"
}

# Drops prefixMatch so probe/action helpers treat the result as an ordinary service.
svc_instance_entry() {
  local entry="$1" instance="$2"

  printf '%s' "$entry" | jq -c --arg id "$instance" '
    (if .type == "windows-schtask" then . + {taskPath: $id} else . + {service: $id} end)
    | del(.prefixMatch)
  '
}

# WHY: prefix match is a literal string-prefix test (index()==1), never a regex;
# registry prefixes contain "." and would otherwise match unrelated ids.
svc_prefix_instances() {
  local entry="$1" svc_type prefix matches

  svc_type="$(printf '%s' "$entry" | jq -r '.type')"
  prefix="$(printf '%s' "$entry" | jq -r '.service // ""')"
  [ -n "$prefix" ] || return 0

  case "$svc_type" in
  macos-launchctl)
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
  nixos-systemctl)
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

# Templates carry an <instance> token expanded to the instance suffix; the service creates the directories, never apply.
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

# WHY: ids come from the registry, not from storage, so the mount manifest drives provisioning and discovery alike, and a mount without a configured remote is declared but never instantiated.
# WHY: the enabled test is `.enable != false`, NOT `.enable // true`, because jq's `//` substitutes on null OR FALSE and enumerated deliberately disabled mounts as configured. Test-NucleusMountEnabled implements the same rule.
svc_configured_instance_ids() {
  local entry="$1" mounts="$2" svc_type prefix task_path ids

  svc_type="$(printf '%s' "$entry" | jq -r '.type')"
  prefix="$(printf '%s' "$entry" | jq -r '.service // ""')"
  task_path="$(printf '%s' "$entry" | jq -r '.taskPath // ""')"

  ids="$(printf '%s' "$mounts" | jq -r '
    .[]? | select((.enable != false) and (.remoteName != null)) | .id
  ')"
  [ -n "$ids" ] || return 0

  case "$svc_type" in
  macos-launchctl)
    while IFS= read -r id; do printf '%s%s\n' "$prefix" "$id"; done <<<"$ids"
    ;;
  nixos-systemctl)
    while IFS= read -r id; do printf '%s%s.service\n' "$prefix" "$id"; done <<<"$ids"
    ;;
  windows-schtask)
    task_path="${task_path%\\}"
    while IFS= read -r id; do printf '%s\\%s%s\n' "$task_path" "$prefix" "$id"; done <<<"$ids"
    ;;
  esac
}

# WHY: the registry is the input the cloud-drives Nix module consumes, so discovery cannot drift from provisioning. Scope is the invoking user.
svc_configured_mounts() {
  local repo_root="$1" host="$2" username="${3:-${SUDO_USER:-$(id -un)}}" lib_dir

  lib_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  "$lib_dir/load-user-registry.sh" --host "$host" --repo-root "$repo_root" |
    jq -c --arg user "$username" '.[$user].cloudDrives.mounts // []'
}

# WHY: the path is <home>/<localPath>, the spelling src/modules/cloud-drives.nix feeds the mount wrapper, so the runtime side never invents a second one. The loader already resolved host-keyed localPath variants, so only a string is a mount point.
svc_cloud_mount_point() {
  local entry="$1" mounts="$2" instance="$3" home="${4:-${HOME:-}}" suffix local_path

  [ -n "$home" ] || return 0
  suffix="$(svc_instance_suffix "$entry" "$instance")"
  # check-suppress:suppression_doc: a mounts array that cannot be parsed yields no mount point, which every caller treats as a service without one; jq reports the parse failure itself.
  local_path="$(printf '%s' "$mounts" | jq -r --arg id "$suffix" '
    [.[]? | select(.id == $id) | .localPath | select(type == "string")] | first // ""
  ')" || return 0
  [ -n "$local_path" ] || return 0

  printf '%s/%s\n' "${home%/}" "$local_path"
}

# WHY: a reload must not start while the previous volume is still attached, or the new mount is destroyed as a duplicate and the drive stays missing until a reboot. Callers report the timeout.
svc_wait_mount_released() {
  local mount_point="$1" timeout="${2:-30}" ticks=0 max_ticks

  [ -n "$mount_point" ] || return 0
  max_ticks=$((timeout * 2))

  while svc_mount_table_contains "$mount_point"; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      return 1
    fi
    sleep 0.5
    ticks=$((ticks + 1))
  done

  return 0
}

# WHY: FSKit can refuse the first attempts right after its daemon restarts (macFUSE status 3/4) while a later one serves the volume, and the mount agent no longer retries a provider refusal on its own, so the bounded retry belongs to the command that wants the mount up. A launch still in flight is never interrupted: an attach may take its own bound, and kicking it again would destroy an attempt that could still succeed.
# An unknown:* answer for the whole budget returns 1 too: it polls without spending a launch, so no launch cap can end such a run.
svc_remount_until() {
  local mount_point="$1" target="$2" sudo_prefix="$3" budget="$4" interval="${5:-5}" max_launches="${6:-4}"
  local start=$SECONDS slept=0 launches=1 announced=false running _srm_state

  while :; do
    _srm_state="$(svc_mount_table_state "$mount_point")"
    if [ "$_srm_state" = present ]; then
      return 0
    fi
    # WHY: the budget is wall clock from the first poll, and the seconds slept are a second bound on that same budget, not a second budget. Every poll also pays the reader's own time, so a clock advanced only by the interval ran roughly three times the stated budget in the one case the unknown arm exists for.
    if [ $((SECONDS - start)) -ge "$budget" ] || [ "$slept" -ge "$budget" ] ||
      [ "$launches" -ge "$max_launches" ]; then
      return 1
    fi
    case "$_srm_state" in
    unknown:*)
      # WHY: the table could not be read, so a kick can land on a volume that is in fact attached. This polls without spending a launch, and the budget check above still ends the run.
      # WHY one notice, and only the first: the caller already said it is starting this mount, so this line is what tells the operator the run is waiting on a read rather than on the mount.
      if [ "$announced" = false ]; then
        notice -l svc-instances \
          "the mount table for '$mount_point' could not be read (${_srm_state#unknown:}); waiting up to ${budget}s for it"
        announced=true
      fi
      ;;
    *)
      running=false
      # WHY: `grep -q` stops at its first match and SIGPIPEs the still-writing probe, which under `set -o pipefail` reads as a failed probe and kicks a launch still in flight. Reading the whole output costs nothing.
      # check-suppress:suppression_doc: a job that is not loaded or not running is the question being asked, not an error.
      if $sudo_prefix launchctl print "$target" 2>/dev/null | grep 'state = running' >/dev/null; then
        running=true
      fi
      if [ "$running" = false ]; then
        # check-suppress:suppression_doc: a launch that fails is retried within the bound; the attempt's output is the agent's log, not this command's.
        $sudo_prefix launchctl kickstart -k "$target" >/dev/null 2>&1 || true
        launches=$((launches + 1))
      fi
      ;;
    esac
    sleep "$interval"
    slept=$((slept + interval))
  done
}

# WHY: the predicate below cannot tell a path that is present from a table it could not read, because it answers "present" for both so no caller starts a mount on top of a possibly-mounted volume. That is right for a caller that acts and wrong for one that reports, so the undeterminable case gets its own value here.
# WHY: the two absent reasons stay apart because the predicate warns on only one. An empty table read nothing at all, which is worth telling the user; a table that does not list the path is the ordinary answer while a remount runs.
# WHY: this prints and nothing else. svc_wait_mount_released polls it every 0.5s and svc_remount_until every 5s, so a warning here would write one line per tick for the whole timeout.
svc_mount_table_state() {
  local mount_point="$1" bound="${2:-10}" status=0 table=""

  # check-suppress:suppression_doc: the reader's own status is classified below rather than propagated; the
  #   bound is carried by the return code, which is re-read immediately.
  table="$(svc_run_bounded "$bound" mount 2>/dev/null)" || status=$?
  if [ "$status" -eq 124 ]; then
    printf 'unknown:probe-bound\n'
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    printf 'unknown:mount-status-%s\n' "$status"
    return 0
  fi
  if [ -z "$table" ]; then
    printf 'absent:empty\n'
    return 0
  fi
  case "$table" in
  *" on $mount_point ("*) printf 'present\n' ;;
  *) printf 'absent:not-listed\n' ;;
  esac
  return 0
}

# WHY: callers act on "not mounted" by starting a mount on top of the volume, so an undeterminable answer must keep reading as present. Callers that report use svc_mount_table_state instead.
# WHY: only the empty table warns, because this is polled every 0.5s for the whole timeout.
svc_mount_table_contains() {
  local state
  state="$(svc_mount_table_state "$@")"
  case "$state" in
  present) return 0 ;;
  absent:empty)
    warn -l svc-instances "the mount table is empty; assuming '$1' is not mounted."
    return 1
    ;;
  absent:not-listed) return 1 ;;
  unknown:probe-bound) return 0 ;;
  unknown:mount-status-*)
    warn -l svc-instances "could not read the mount table (mount exited ${state##*-}); assuming '$1' is mounted."
    return 0
    ;;
  esac
}

# WHY: a hung macFUSE/FSKit volume blocks the mount table and any stat of the volume inside the kernel, and these scripts have no 'timeout' binary on PATH, so a probe that can touch a mount carries its own bound. One dead volume would hang the watchdog and the whole nucleus-svc CLI.
svc_run_bounded() {
  local bound="$1"
  shift
  local pid ticks=0 max_ticks
  max_ticks=$((bound * 5))

  "$@" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      # check-suppress:suppression_doc: the command already outlived its bound; signalling and reaping a process that ignores the signal must not change the timeout answer.
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      # check-suppress:suppression_doc: same as above: the kill and the reap are best effort, the bound is the answer.
      kill -KILL "$pid" 2>/dev/null || true
      # check-suppress:suppression_doc: same as above.
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done

  wait "$pid"
}

# WHY: the list is written by this shell, so a reader stopping at its first match would SIGPIPE the write and report a present value as missing.
svc_list_contains() {
  local list="$1" value="$2"

  [ -n "$list" ] || return 1
  grep -qxF "$value" <<<"$list"
}
