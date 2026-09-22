#!/usr/bin/env bash
# Clear stale fskit-provider blocked markers for ALL services after
# setupLaunchAgents restarts agents.
#
# WHY: nucleus-apply provisions the entire system.  Any service that wrote a
# blocked fskit-provider marker (because the FSKit extension was temporarily
# unavailable) should have it cleared when the extension is now available —
# this is normal provisioning behavior, not an edge case.  The blocked marker
# is runtime state that says "the extension was unavailable during the last
# attempt"; after apply re-provisions the system (re-registers the extension,
# restarts agents), that state is stale and must be cleared.
#
# Called from src/modules/cloud-drives.nix activation entry (entryAfter
# setupLaunchAgents).  On non-Darwin hosts this is a no-op — NixOS uses systemd
# and has no FSKit.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/crash-loop.sh
. "$SCRIPT_DIR/../lib/crash-loop.sh"
# shellcheck source=../lib/svc-instances.sh
. "$SCRIPT_DIR/../lib/svc-instances.sh"

# ── Arguments ────────────────────────────────────────────────────────────────
# $1 — jq binary path (from Nix store)
_csb_jq_bin="$1"
_csb_repo_root="$(derive_repo_root)"
_csb_services_json="$_csb_repo_root/src/modules/services.json"
_csb_host="$(resolve_nucleus_host)"

# On non-Darwin: nothing to clear — NixOS uses systemd, no FSKit.
case "$(uname -s)" in
Darwin) ;;
*)
  exit 0
  ;;
esac

# shellcheck source=../lib/macos-fskit.sh
. "$SCRIPT_DIR/../lib/macos-fskit.sh"

# ── Check FSKit extension availability ──────────────────────────────────────
# If the extension is not enabled, there is nothing to clear — the extension
# is genuinely broken and the blocked markers are correct.
_csb_fskit_state="$(fskit_macfuse_module_state)"
if [ "$_csb_fskit_state" != "enabled" ]; then
  notice -l cloud-drives "clear-stale-blocks: FSKit extension state is $_csb_fskit_state; skipping block clearing"
  exit 0
fi

# ── Find all macOS LaunchAgent labels currently loaded ───────────────────────
# Iterate the services.json to find macOS launchctl services.  For prefix-match
# entries (like cloud-drive), expand to concrete instance ids using the user
# registry.  For ordinary services, use the declared service label directly.
_csb_state_dir="$(crash_loop_state_dir)"
_csb_repo_root="$(derive_repo_root)"

# Build a newline-separated list of all launchd labels to check.
_csb_labels=""

# Process each service entry for the current host.
# shellcheck disable=SC2016 # reason: jq filter — single quotes required, $host is jq --arg, not shell
_csb_host_entries="$("$_csb_jq_bin" -c --arg host "$_csb_host" '
  to_entries[]
  | select(.value | type == "object")
  | select(.value.hosts | has($host))
  | select(.value.hosts[$host].type != "omitted")
  | {key: .key, hostEntry: .value.hosts[$host]}
' "$_csb_services_json")"
while IFS= read -r _csb_entry_json; do
  [ -z "$_csb_entry_json" ] && continue

  _csb_key="$(printf '%s' "$_csb_entry_json" | "$_csb_jq_bin" -r '.key')"
  _csb_host_entry="$(printf '%s' "$_csb_entry_json" | "$_csb_jq_bin" -c '.hostEntry')"
  _csb_is_prefix="$(printf '%s' "$_csb_host_entry" | "$_csb_jq_bin" -r '.prefixMatch // false')"
  _csb_svc_type="$(printf '%s' "$_csb_host_entry" | "$_csb_jq_bin" -r '.type')"
  _csb_scope="$(printf '%s' "$_csb_host_entry" | "$_csb_jq_bin" -r '.scope // "system"')"
  _csb_launchd_domain="$(printf '%s' "$_csb_host_entry" | "$_csb_jq_bin" -r '.launchdDomain // "gui"')"

  # Only process macOS launchctl services.
  [ "$_csb_svc_type" = "macos-launchctl" ] || continue

  if [ "$_csb_is_prefix" = "true" ]; then
    # Prefix-match entry: expand to concrete instance ids from the user registry.
    _csb_mounts="$(svc_configured_mounts "$_csb_repo_root" "$_csb_host")"
    while IFS= read -r _csb_instance_id; do
      [ -n "$_csb_instance_id" ] && _csb_labels="${_csb_labels}${_csb_instance_id}"$'\n'
    done < <(svc_configured_instance_ids "$_csb_host_entry" "$_csb_mounts")
  else
    # Ordinary service: use the declared service label.
    _csb_svc_label="$(printf '%s' "$_csb_host_entry" | "$_csb_jq_bin" -r '.service // ""')"
    [ -n "$_csb_svc_label" ] && _csb_labels="${_csb_labels}${_csb_svc_label}"$'\n'
  fi
done <<<"$_csb_host_entries"

# ── Check each label for a stale fskit-provider block ───────────────────────
_csb_cleared=0
while IFS= read -r _csb_label; do
  [ -z "$_csb_label" ] && continue

  _csb_blocked="$(svc_blocked_state "$_csb_label" "$_csb_state_dir")"
  case "$_csb_blocked" in
  "blocked fskit-provider")
    svc_blocked_clear "$_csb_label" "$_csb_state_dir"
    notice -l cloud-drives "clear-stale-blocks: cleared stale fskit-provider block for $_csb_label"

    # Kickstart the agent so it restarts immediately instead of waiting for
    # the watchdog's next 300s tick.
    # check-suppress:suppression_doc: kickstart of a job that is not loaded is a no-op; best-effort recovery.
    launchctl kickstart "gui/$(id -u)/$_csb_label" 2>/dev/null || true
    _csb_cleared=$((_csb_cleared + 1))
    ;;
  esac
done <<<"$(printf '%s\n' "$_csb_labels")"

if [ "$_csb_cleared" -gt 0 ]; then
  notice -l cloud-drives "clear-stale-blocks: cleared $_csb_cleared stale fskit-provider block(s)"
fi
