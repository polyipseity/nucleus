#!/usr/bin/env bash
# shellcheck shell=bash
# Cloud-mount core runner (POSIX).
# Bounded retry with backoff, classification, health records.
# Dispatches to mount-backend-darwin.sh or mount-backend-linux.sh.
# No OS/FUSE/supervisor names — all host details in adapters.
#
# Consumed by:
#   macOS LaunchAgent (via writeNucleusShellApplication)
#   NixOS systemd unit (same derivation, different backend)
#
# Environment (injected by Nix extraEnv or shell wrapper):
#   NUCLEUS_RCLONE_REMOTE_NAME  — display name
#   NUCLEUS_RCLONE_REMOTE       — rclone remote
#   NUCLEUS_RCLONE_MOUNT_POINT  — local mount path
#   NUCLEUS_RCLONE_ARGS         — newline-separated rclone flags
#   NUCLEUS_CLOUD_MOUNT_INSTANCE — instance key (e.g. "iCloud")
#
# Lifecycle policy (injected by Nix or parsed from services.json):
#   NUCLEUS_MOUNT_ATTEMPTS      — max retry attempts (default 3)
#   NUCLEUS_MOUNT_BACKOFF       — comma-separated backoff seconds (default "20,40")
#   NUCLEUS_MOUNT_ATTACH_SECONDS — attach budget (default 45)

[ -n "${_NUCLEUS_RCLONE_MOUNT_SOURCED-}" ] && return
_NUCLEUS_RCLONE_MOUNT_SOURCED=1

_CM_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_CM_DIR/../lib/lib.sh"
# shellcheck source=../lib/service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_CM_DIR/../lib/service-health.sh"

# Dispatch to the correct mount backend based on OS.
_cm_dispatch_backend() {
  case "$(uname -s)" in
  Darwin)
    # shellcheck source=../lib/mount-backend-darwin.sh
    . "$_CM_DIR/../lib/mount-backend-darwin.sh"
    ;;
  *)
    # shellcheck source=../lib/mount-backend-linux.sh
    . "$_CM_DIR/../lib/mount-backend-linux.sh"
    ;;
  esac
}

# _cm_parse_backoff — parse the backoff schedule into an array.
_cm_parse_backoff() {
  local backoff_csv="${NUCLEUS_MOUNT_BACKOFF:-20,40}"
  IFS=',' read -ra _cm_backoff <<<"$backoff_csv"
}

# _cm_get_backoff — get the backoff seconds for a given attempt (1-indexed).
_cm_get_backoff() {
  local attempt="$1"
  if [ "$attempt" -le "${#_cm_backoff[@]}" ]; then
    printf '%s' "${_cm_backoff[$((attempt - 1))]}"
  else
    # Extrapolate: last value + 20 for each additional attempt.
    printf '%s' "$((${_cm_backoff[${#_cm_backoff[@]} - 1]} + 20 * (attempt - ${#_cm_backoff[@]})))"
  fi
}

# main — the core mount loop.
_cm_main() {
  local instance="${NUCLEUS_CLOUD_MOUNT_INSTANCE:?}"
  local remote="${NUCLEUS_RCLONE_REMOTE:?}"
  local mount_point="${NUCLEUS_RCLONE_MOUNT_POINT:?}"
  local rclone_args="${NUCLEUS_RCLONE_ARGS:-}"
  local read_only="${NUCLEUS_RCLONE_READ_ONLY:-false}"
  local rclone_bin="${NUCLEUS_RCLONE_BIN:-rclone}"

  local attempts="${NUCLEUS_MOUNT_ATTEMPTS:-3}"
  local attach_seconds="${NUCLEUS_MOUNT_ATTACH_SECONDS:-45}"

  # Dispatch to the correct backend.
  _cm_dispatch_backend

  # Parse backoff schedule.
  _cm_parse_backoff

  # Initialize health record.
  svc_health_init "$instance"

  # Backend prepare (idempotent; may write blocked record + return 20).
  local prepare_rc=0
  backend_prepare "$instance" || prepare_rc=$?
  if [ "$prepare_rc" -eq 20 ]; then
    notice -l cloud-drives "$instance: backend requires user action; see health record"
    exit 0
  fi

  # Bounded retry loop.
  local attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    # If a blocked record exists, do not attempt.
    if svc_health_is_blocked "$instance"; then
      notice -l cloud-drives "$instance: blocked (class=$(svc_health_get "$instance" "class")); not attempting"
      exit 0
    fi

    notice -l cloud-drives "$instance: mount attempt $attempt/$attempts"

    # Set up stderr capture for classification.
    local capture_file
    capture_file="$(mktemp)"
    _backend_capture="$capture_file"

    # Run rclone mount via backend.
    local mount_args_file
    mount_args_file="$(mktemp)"
    backend_args "$remote" "$mount_point" "$read_only" "$rclone_args" >"$mount_args_file"
    backend_mount "$rclone_bin" "$(<"$mount_args_file")"

    # Wait for the volume to appear.
    local attach_start=$SECONDS
    local live=false
    while [ $((SECONDS - attach_start)) -lt "$attach_seconds" ]; do
      if backend_probe "$mount_point"; then
        live=true
        break
      fi
      sleep 1
    done

    if [ "$live" = true ]; then
      # Mount succeeded — record and watch.
      svc_health_set_running "$instance"
      svc_health_record_success "$instance"
      svc_health_increment_runs "$instance"
      rm -f "$capture_file" "$mount_args_file"

      # Watch for the mount to stay alive or exit.
      local watch_status=0
      wait "$_backend_rclone_pid" || watch_status=$?

      # Mount exited — record and exit.
      svc_health_set_last_exit "$instance" "$watch_status"
      # check-suppress:suppression_doc: best-effort unmount after mount failure
      backend_unmount "$mount_point" 2>/dev/null || true
      notice -l cloud-drives "$instance: mount exited with status $watch_status"
      exit "$watch_status"
    fi

    # Mount did not attach — classify the failure.
    local class
    class="$(backend_class "$capture_file")"
    local remedy
    remedy="$(backend_remedy "$class")"

    # Kill the rclone process if still running.
    if [ -n "${_backend_rclone_pid:-}" ] && kill -0 "$_backend_rclone_pid" 2>/dev/null; then
      # check-suppress:suppression_doc: kill may fail if rclone already exited
      kill -TERM "$_backend_rclone_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: wait may fail if rclone already exited
      wait "$_backend_rclone_pid" 2>/dev/null || true
    fi

    notice -l cloud-drives "$instance: attempt $attempt failed (class=$class, $remedy)"

    # Check if transient — terminal classes stop immediately.
    if ! backend_is_transient "$class"; then
      svc_health_set_blocked "$instance" "$class" "$remedy"
      rm -f "$capture_file" "$mount_args_file"
      exit 0
    fi

    # Transient — backoff and retry.
    rm -f "$capture_file" "$mount_args_file"
    if [ "$attempt" -lt "$attempts" ]; then
      local backoff
      backoff=$(_cm_get_backoff "$attempt")
      notice -l cloud-drives "$instance: retrying in ${backoff}s"
      sleep "$backoff"
    fi

    attempt=$((attempt + 1))
  done

  # Exhausted all attempts — write blocked record.
  local final_class="mount-failed"
  local final_remedy
  final_remedy="$(backend_remedy "$final_class")"
  svc_health_set_blocked "$instance" "$final_class" "$final_remedy"
  notice -l cloud-drives "$instance: all $attempts attempts exhausted; blocked"
  exit 0
}

# Run if executed directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cm_main "$@"
fi
