#!/usr/bin/env bash
# Cloud drive pre-stop: stop all cloud mount LaunchAgents and wait for their
# volumes to release before setupLaunchAgents runs its bootout+bootstrap cycle.
#
# WHY: during nucleus-apply, setupLaunchAgents detects plist changes and does
# bootout+bootstrap on cloud mount agents.  If the old mount's FSKit volume
# hasn't fully released by the time the new agent starts, the mount script
# detects the stale volume and runs diskutil unmount force.  That force-unmount
# can trigger lsd to re-register the FSKit extension with a new UUID (Apple bug
# on macOS 26), causing the mount to fail with a stale UUID reference.  By
# stopping agents and waiting for volumes to release before setupLaunchAgents
# runs, we eliminate the stale volume and the force-unmount trigger.
#
# Called from src/modules/cloud-drives.nix activation entry (entryBefore
# setupLaunchAgents).  On non-Darwin hosts this is a no-op — NixOS uses systemd
# and has no FSKit.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

# ── Arguments ────────────────────────────────────────────────────────────────
# $1 — jq binary path (from Nix store)
# $2 — mounts JSON array (from cloud-drives Nix module)
_psd_jq_bin="$1"
_psd_mounts_json="$2"

# On non-Darwin: nothing to stop — NixOS uses systemd, no FSKit.
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

  # Stop the LaunchAgent.  The agent may not be loaded (first apply, or was
  # already stopped), so bootout failure is not fatal.
  # check-suppress:suppression_doc: bootout of a job that is not loaded is an expected no-op.
  launchctl bootout "$_psd_target" 2>/dev/null || true

  # Wait for the volume to release from the mount table.  15 seconds is long
  # enough for FSKit to clean up after the old agent's SIGTERM, but short
  # enough to not delay apply significantly.
  if svc_wait_mount_released "$_psd_mount_point" 15; then
    notice -l cloud-drives "pre-stop: volume at $_psd_mount_point released"
  else
    warn -l cloud-drives "pre-stop: volume at $_psd_mount_point still attached after 15s; setupLaunchAgents will handle it"
  fi
done < <(printf '%s\n' "$_psd_mounts_json" | "$_psd_jq_bin" -r -c '.[]')
