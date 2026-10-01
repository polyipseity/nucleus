#!/usr/bin/env bash
# Create the mount point and replica directories. A mount blocked by the previous
# attempt is reported with its recorded remedy, so a missing drive is never silent.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/service-health.sh
. "$SCRIPT_DIR/../lib/service-health.sh"
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

# _cd_ensure_real_directory PATH DISPLAY_NAME SERVICE_LABEL
# WHY SERVICE_LABEL: it names the supervisor unit owning a mount there (macOS
# LaunchAgent label, systemd unit base name) so the remedy can quote it. May be empty.
_cd_ensure_real_directory() {
  _cd_path="$1"
  _cd_name="$2"
  _cd_service_label="${3-}"

  if [ -L "$_cd_path" ]; then
    # WHY: a symlink here is either the leftover of the retired /Volumes layout,
    #   whose mount point never existed so the link dangles, or a user-placed link.
    #   The literal $(id -u) is for the operator to paste, not to expand.
    _cd_remedy="fix manually and re-apply"
    if [ -n "$_cd_service_label" ]; then
      _cd_remedy="if a cloud drive mount is still attached there, unload its agent with launchctl bootout \"gui/\$(id -u)/$_cd_service_label\", then remove the symlink with rm \"$_cd_path\" and re-apply"
    fi
    printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_path is a symlink to $(readlink "$_cd_path"); $_cd_remedy" >&2
    exit 1
  fi
  if [ -e "$_cd_path" ] && [ ! -d "$_cd_path" ]; then
    printf '%s\n' "cloud-drives (${_cd_name}): error: $_cd_path exists and is not a directory; fix manually and re-apply" >&2
    exit 1
  fi
  # WHY not an error: only a provider repair brings the volume back, and the mount
  #   records that itself once it attaches. The marker is boot-scoped.
  mkdir -p "$_cd_path"
}

_vsd_jq_bin="$1"
_vsd_mounts_json="$2"
_vsd_replicas_json="$3"

mkdir -p "$HOME/clouds"

# WHY a real directory on macOS too: rclone stats the mount point before
# mounting, so macFUSE never creates one under /Volumes.
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _vsd_service_label="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.serviceLabel // empty')"
  _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_local_path" "$_vsd_service_label"

  # WHY a warning, not an error: failing the apply here would block convergence
  #   of everything else for a state this script cannot fix.
  if [ -n "$_vsd_service_label" ]; then
    if svc_health_is_blocked "$_vsd_service_label"; then
      _vsd_class=$(svc_health_get "$_vsd_service_label" "class" 2>/dev/null || echo "unknown")
      _vsd_remedy=$(svc_health_get "$_vsd_service_label" "remedy" 2>/dev/null || echo "")
      printf '%s\n' "cloud-drives ($_vsd_local_path): warning: the last mount attempt was blocked ($_vsd_class); $_vsd_remedy" >&2
    fi
  fi
done < <(printf '%s\n' "$_vsd_mounts_json" | "$_vsd_jq_bin" -r -c '.[]')

while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_local_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.localPath')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.name')"
  _vsd_is_special_icloud="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.isSpecialICloud')"

  if [ "$_vsd_is_special_icloud" = "true" ]; then
    # WHY: iCloudReplica must point at native CloudDocs storage so we do not run a
    #   second managed tree beside Apple's own iCloud integration. The
    #   isSpecialICloud flag is set at Nix eval time on Darwin only.
    _vsd_icloud_native_target="$HOME/Library/Mobile Documents"
    _vsd_icloud_replica_path="$HOME/$_vsd_local_path"

    if [ -L "$_vsd_icloud_replica_path" ]; then
      if [ "$(readlink "$_vsd_icloud_replica_path")" != "$_vsd_icloud_native_target" ]; then
        printf '%s\n' "cloud-drives ($_vsd_display_name): error: $_vsd_icloud_replica_path must symlink to $_vsd_icloud_native_target; fix manually and re-apply" >&2
        exit 1
      fi
    elif [ -e "$_vsd_icloud_replica_path" ]; then
      printf '%s\n' "cloud-drives ($_vsd_display_name): error: $_vsd_icloud_replica_path exists and is not the native iCloud symlink; fix manually and re-apply" >&2
      exit 1
    else
      ln -s "$_vsd_icloud_native_target" "$_vsd_icloud_replica_path"
      printf '%s\n' "cloud-drives ($_vsd_display_name): linked $_vsd_icloud_replica_path -> $_vsd_icloud_native_target (native iCloud replica path)."
    fi
  else
    _cd_ensure_real_directory "$HOME/$_vsd_local_path" "$_vsd_display_name"
  fi
done < <(printf '%s\n' "$_vsd_replicas_json" | "$_vsd_jq_bin" -r -c '.[]')
