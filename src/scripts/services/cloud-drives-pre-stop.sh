#!/usr/bin/env bash
# Cloud drive pre-stop: stop all cloud mount LaunchAgents and wait for their
# volumes to release before setupLaunchAgents runs its bootout+bootstrap cycle.
#
# WHY: if the old mount's FSKit volume has not released when the new agent
# starts, the mount script force-unmounts the stale volume, and that can make
# lsd re-register the FSKit extension with a new UUID (Apple bug on macOS 26)
# so the mount fails on a stale UUID.
#
# Called from the cloud-drives.nix activation entry, entryBefore
# setupLaunchAgents. No-op off Darwin: NixOS uses systemd and has no FSKit.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

# $1 jq binary path (from the Nix store), $2 mounts JSON array
_psd_jq_bin="$1"
_psd_mounts_json="$2"

# WHY: not Darwin means nothing to stop. NixOS uses systemd, no FSKit.
case "$(uname -s)" in
Darwin) ;;
*)
  exit 0
  ;;
esac

# ── Stop each cloud mount LaunchAgent and wait for its volume ────────────────
# Iterate the mounts JSON array.  For each enabled mount with a configured
# remote (i.e. one that has a running LaunchAgent), send bootout to stop the
# agent and wait for the FSKit volume to release from the mount table.
while IFS= read -r _psd_entry; do
  [ -z "$_psd_entry" ] && continue

  _psd_id="$(printf '%s\n' "$_psd_entry" | "$_psd_jq_bin" -r '.id')"
  _psd_local_path="$(printf '%s\n' "$_psd_entry" | "$_psd_jq_bin" -r '.localPath')"
  _psd_service_label="$(printf '%s\n' "$_psd_entry" | "$_psd_jq_bin" -r '.serviceLabel // empty')"

  # Skip mounts without a service label — these have no LaunchAgent.
  [ -n "$_psd_service_label" ] || continue

  _psd_mount_point="$HOME/$_psd_local_path"
  _psd_target="gui/$(id -u)/$_psd_service_label"

  notice -l cloud-drives "pre-stop: stopping $_psd_service_label for volume at $_psd_mount_point"

  # Bootout failure is expected: the agent may not be loaded (first apply, or
  # already stopped).
  # check-suppress:suppression_doc: bootout of a job that is not loaded is an expected no-op.
  launchctl bootout "$_psd_target" 2>/dev/null || true

  # WHY: 15s covers FSKit cleanup after the old agent's SIGTERM without
  # meaningfully delaying apply.
  if svc_wait_mount_released "$_psd_mount_point" 15; then
    notice -l cloud-drives "pre-stop: volume at $_psd_mount_point released"
  else
    warn -l cloud-drives "pre-stop: volume at $_psd_mount_point still attached after 15s; setupLaunchAgents will handle it"
  fi
done < <(printf '%s\n' "$_psd_mounts_json" | "$_psd_jq_bin" -r -c '.[]')
