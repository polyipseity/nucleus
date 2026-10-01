#!/usr/bin/env bash
# shellcheck shell=bash
# Cloud-mount core runner (POSIX). Bounded retry with backoff, failure
# classification and health records, with host details left to the adapters in
# mount-backend-*.sh. Consumed by the macOS LaunchAgent and the NixOS systemd
# unit.
#
# Environment, injected by Nix extraEnv or the shell wrapper:
#   NUCLEUS_RCLONE_REMOTE       rclone remote
#   NUCLEUS_RCLONE_MOUNT_POINT  local mount path
#   NUCLEUS_RCLONE_ARGS         newline-separated rclone flags
#   NUCLEUS_CLOUD_MOUNT_INSTANCE instance key (e.g. "iCloud")
#
# Lifecycle policy, injected by Nix from services.json cloud-drive.lifecycle:
#   NUCLEUS_MOUNT_ATTEMPTS      max retry attempts
#   NUCLEUS_MOUNT_BACKOFF       comma-separated backoff seconds
#   NUCLEUS_MOUNT_ATTACH_SECONDS attach budget
#
# WHY: no shell strict mode. The generated app wrapper sets `set -euo pipefail`
#   but shell options do not survive `exec`, so that hardens the wrapper, not
#   this script. Failure handling here is explicit instead: `set -e` would change
#   control flow in the retry loop, where the svc_health_* writes and
#   backend_mount must be allowed to fail so the attach wait, the classification,
#   the blocked record and the retry all still run. Aborting instead of
#   classifying exits the unit and invites the supervisor to revive it, the
#   restart storm this design exists to prevent. The Windows runner hardens
#   itself with $ErrorActionPreference = 'Stop'; that asymmetry is deliberate.

[ -n "${_NUCLEUS_RCLONE_MOUNT_SOURCED-}" ] && return
_NUCLEUS_RCLONE_MOUNT_SOURCED=1

_CM_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_CM_DIR/../lib/lib.sh"
# shellcheck source=../lib/service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_CM_DIR/../lib/service-health.sh"

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

_cm_parse_backoff() {
  local backoff_csv="${NUCLEUS_MOUNT_BACKOFF:?}"
  IFS=',' read -ra _cm_backoff <<<"$backoff_csv"
}

# WHY: the declared schedule is clamped, never extrapolated
#   (services.schema.json, mountRetryBackoffSeconds), so every delay this runner
#   sleeps is a value services.json declares. The Windows runner clamps identically.
_cm_get_backoff() {
  local attempt="$1"
  local _cm_idx=$((attempt - 1))
  local _cm_last=$((${#_cm_backoff[@]} - 1))
  if [ "$_cm_idx" -gt "$_cm_last" ]; then
    _cm_idx="$_cm_last"
  fi
  printf '%s' "${_cm_backoff[$_cm_idx]}"
}

_cm_main() {
  local instance="${NUCLEUS_CLOUD_MOUNT_INSTANCE:?}"
  local remote="${NUCLEUS_RCLONE_REMOTE:?}"
  local mount_point="${NUCLEUS_RCLONE_MOUNT_POINT:?}"
  local rclone_args="${NUCLEUS_RCLONE_ARGS:-}"
  local read_only="${NUCLEUS_RCLONE_READ_ONLY:-false}"
  local rclone_bin="${NUCLEUS_RCLONE_BIN:-rclone}"

  local attempts="${NUCLEUS_MOUNT_ATTEMPTS:?}"
  local attach_seconds="${NUCLEUS_MOUNT_ATTACH_SECONDS:?}"

  _cm_dispatch_backend
  _cm_parse_backoff
  svc_health_init "$instance"

  # Backend prepare is idempotent and may write a blocked record, returning 20.
  local prepare_rc=0
  backend_prepare "$instance" || prepare_rc=$?
  if [ "$prepare_rc" -eq 20 ]; then
    notice -l cloud-drives "$instance: backend requires user action; see health record"
    exit 0
  fi

  local attempt=1
  # Set when the attach wait ended on a table that could not be read, so the
  # record can say the read failed rather than the mount failed.
  local probe_unknown=false
  while [ "$attempt" -le "$attempts" ]; do
    if svc_health_is_blocked "$instance"; then
      notice -l cloud-drives "$instance: blocked (class=$(svc_health_get "$instance" "class")); not attempting"
      exit 0
    fi

    notice -l cloud-drives "$instance: mount attempt $attempt/$attempts"

    local capture_file
    capture_file="$(mktemp)"
    _backend_capture="$capture_file"

    local mount_args_file
    mount_args_file="$(mktemp)"
    backend_args "$remote" "$mount_point" "$read_only" "$rclone_args" >"$mount_args_file"
    # WHY: backend_args emits one token per line. Passing "$(<file)" collapses that
    # into a single argument, so rclone receives one blob where it expects the
    # remote, mount point and flags as separate argv entries. Reading line by line
    # preserves a token that itself contains a space, which matters because a
    # mount point can live under a path with spaces. (No mapfile: the interpreter
    # is bash 3.2 on macOS.)
    local -a mount_args=()
    local _cm_arg_line
    while IFS= read -r _cm_arg_line; do
      if [ -n "$_cm_arg_line" ]; then
        mount_args+=("$_cm_arg_line")
      fi
    done <"$mount_args_file"
    backend_mount "$rclone_bin" "${mount_args[@]}"

    local attach_start=$SECONDS
    local live=false
    local probe_state=""
    # How the wait ended, as opposed to what its last probe answered. The two
    # disagree when the loop breaks on a dead child after a readable absent answer.
    local exit_reason=""
    while [ $((SECONDS - attach_start)) -lt "$attach_seconds" ]; do
      # WHY: backend_probe_state keeps the third value. A two-valued answer is 0
      #   both for a live mount and for a table that could not be read, and this
      #   loop acts on that 0 by recording the service running and deleting the
      #   capture file. An unknown state takes the same poll as absent, spends no
      #   attempt, and the budget ends the run.
      probe_state="$(backend_probe_state "$mount_point")"
      if [ "$probe_state" = present ]; then
        live=true
        exit_reason="attached"
        break
      fi
      # WHY: a mount that dies during startup would otherwise be polled for the whole
      #   budget before anything classified it, even though the capture file
      #   already held the reason. An unreaped child is a zombie and kill -0
      #   succeeds on a zombie, but the probe and sleep are foreground children, so
      #   bash reaps between polls and the worst case is one extra poll.
      if ! kill -0 "${_backend_rclone_pid:-}" 2>/dev/null; then
        exit_reason="child-exited"
        break
      fi
      sleep 1
    done

    [ -n "$exit_reason" ] || exit_reason="budget"

    if [ "$live" = true ]; then
      # No generation bump here: the run token belongs to the supervisor and the
      # watchdog reads a restart from a change in it, so advancing it on a
      # successful start would register a phantom restart on every mount.
      svc_health_set_running "$instance"
      svc_health_record_success "$instance"
      # WHY: reaching running ends the failure the pointer was written for, and a
      #   record still naming a retained capture file would point whoever reads it
      #   at evidence for a mount that is now healthy.
      svc_health_set "$instance" evidence null
      rm -f "$capture_file" "$mount_args_file"

      local watch_status=0
      wait "$_backend_rclone_pid" || watch_status=$?

      svc_health_set_last_exit "$instance" "$watch_status"
      # check-suppress:suppression_doc: best-effort unmount after mount failure
      backend_unmount "$mount_point" 2>/dev/null || true
      notice -l cloud-drives "$instance: mount exited with status $watch_status"
      exit "$watch_status"
    fi

    local class
    class="$(backend_class "$capture_file")"
    # WHY: an unreadable table says nothing about the mount. backend_class reads
    #   rclone's output and answers mount-failed when it finds no cause there,
    #   blaming the mount for a read nobody could make and sending the operator to
    #   check the remote. io-transient is the class whose remedy is to try again.
    # WHY: there is no `attached` arm, because the wait can only end attached when
    #   live is true, and the success path exits before reaching this case. The
    #   `*)` arm covers an ending this code cannot place and reads it as
    #   io-transient, the class that costs a retry, over the terminal classes that
    #   stop the run on the strength of a read that never completed.
    case "$exit_reason" in
    child-exited | budget)
      if [ "${probe_state#unknown:}" != "$probe_state" ]; then
        probe_unknown=true
        class="io-transient"
      else
        probe_unknown=false
      fi
      ;;
    *)
      probe_unknown=true
      class="io-transient"
      ;;
    esac
    local remedy
    remedy="$(backend_remedy "$class")"

    if [ -n "${_backend_rclone_pid:-}" ] && kill -0 "$_backend_rclone_pid" 2>/dev/null; then
      # check-suppress:suppression_doc: kill may fail if rclone already exited
      kill -TERM "$_backend_rclone_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: wait may fail if rclone already exited
      wait "$_backend_rclone_pid" 2>/dev/null || true
    fi

    notice -l cloud-drives "$instance: attempt $attempt failed (class=$class, $remedy)"

    # WHY: the capture file is kept only on the unreadable-table path, where the
    #   class in the health record is one this runner chose rather than one
    #   rclone's output supports, so the file is the only remaining record of what
    #   the mount was doing. The record carries one path, not a list, so a run
    #   that keeps a file on several attempts leaves the earlier ones unreachable.
    if [ "$probe_unknown" = true ]; then
      # WHY: svc_health_set interpolates the value into a jq program, so a bare
      #   path is a jq syntax error the runner would discard silently.
      svc_health_set "$instance" evidence "\"$capture_file\""
      notice -l cloud-drives "$instance: rclone output kept at $capture_file"
    else
      # WHY: no clear of the evidence field accompanies this removal. The field can
      #   only name an earlier attempt's kept file, so it never names the one going
      #   away. A run that kept a file on an unreadable table and reached this
      #   branch later strands that earlier file, which is the condition the field
      #   exists to remove. The success path strands one too, and a blocked record
      #   still has a failure to name.
      rm -f "$capture_file"
    fi
    rm -f "$mount_args_file"

    if ! backend_is_transient "$class"; then
      svc_health_set_blocked "$instance" "$class" "$remedy"
      exit 0
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      local backoff
      backoff=$(_cm_get_backoff "$attempt")
      notice -l cloud-drives "$instance: retrying in ${backoff}s"
      sleep "$backoff"
    fi

    attempt=$((attempt + 1))
  done

  # WHY: the last attempt's own diagnosis must not be overwritten. $class holds it
  #   because the loop reassigns it on every pass, no other health record carries
  #   that classification out of the loop, and the capture file kept on the
  #   unreadable-table path holds rclone's raw output rather than a class. Reading
  #   $class here is not a scope error: `local` binds to the enclosing function,
  #   not the block, so the name still resolves after the loop closes. A
  #   NUCLEUS_MOUNT_ATTEMPTS that is not a number leaves the loop body unrun and
  #   $class empty, which services.schema.json rules out.
  local final_class="$class"
  if [ "$probe_unknown" = true ]; then
    final_class="io-transient"
  fi
  local final_remedy
  final_remedy="$(backend_remedy "$final_class")"
  svc_health_set_blocked "$instance" "$final_class" "$final_remedy"
  notice -l cloud-drives "$instance: all $attempts attempts exhausted; blocked"
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cm_main "$@"
fi
