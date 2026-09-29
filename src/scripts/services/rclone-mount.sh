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
#   NUCLEUS_RCLONE_REMOTE       — rclone remote
#   NUCLEUS_RCLONE_MOUNT_POINT  — local mount path
#   NUCLEUS_RCLONE_ARGS         — newline-separated rclone flags
#   NUCLEUS_CLOUD_MOUNT_INSTANCE — instance key (e.g. "iCloud")
#
# Lifecycle policy (injected by Nix from services.json cloud-drive.lifecycle):
#   NUCLEUS_MOUNT_ATTEMPTS      — max retry attempts
#   NUCLEUS_MOUNT_BACKOFF       — comma-separated backoff seconds
#   NUCLEUS_MOUNT_ATTACH_SECONDS — attach budget
#
# WHY: this runner deliberately sets no shell strict mode.  It is launched through the
#   generated nucleus app wrapper (writeNucleusShellApplication in src/flake.nix), which
#   does set `set -euo pipefail` — but shell options do NOT survive `exec`, so that
#   setting hardens the wrapper, not this script.  (The wrapper's inline-`text` branch is
#   hardened; the thin-wrapper branch is not.)  Failure handling here is explicit instead:
#   `cmd || rc=$?` where the status is inspected, `|| true` for best-effort cleanup, and
#   explicit `exit` codes.  Adding `set -e` would CHANGE control flow in the retry loop,
#   because several calls must be allowed to fail: the svc_health_* writes (deliberately
#   non-fatal; see the F1/F5 fixes) and backend_mount, whose failure must still reach the
#   attach wait, the failure classification, the blocked record and the retry.  Aborting
#   instead of classifying exits the unit, which invites the supervisor to revive it —
#   the restart storm this design exists to prevent.  The Windows runner hardens itself
#   with $ErrorActionPreference = 'Stop'; that asymmetry is deliberate and documented, not
#   an oversight.

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
  local backoff_csv="${NUCLEUS_MOUNT_BACKOFF:?}"
  IFS=',' read -ra _cm_backoff <<<"$backoff_csv"
}

# _cm_get_backoff — get the backoff seconds for a given attempt (1-indexed).
#
# WHY: the declared schedule is CLAMPED, never extrapolated (services.schema.json,
#   mountRetryBackoffSeconds).  An attempt past the end of the list reuses the last declared value, so
#   every delay this runner sleeps is a value services.json actually declares and no runner
#   invents one of its own.  The Windows runner clamps identically (rclone-mount.ps1), and
#   the two hosts must not diverge on this rule.
_cm_get_backoff() {
  local attempt="$1"
  local _cm_idx=$((attempt - 1))
  local _cm_last=$((${#_cm_backoff[@]} - 1))
  if [ "$_cm_idx" -gt "$_cm_last" ]; then
    _cm_idx="$_cm_last"
  fi
  printf '%s' "${_cm_backoff[$_cm_idx]}"
}

# main — the core mount loop.
_cm_main() {
  local instance="${NUCLEUS_CLOUD_MOUNT_INSTANCE:?}"
  local remote="${NUCLEUS_RCLONE_REMOTE:?}"
  local mount_point="${NUCLEUS_RCLONE_MOUNT_POINT:?}"
  local rclone_args="${NUCLEUS_RCLONE_ARGS:-}"
  local read_only="${NUCLEUS_RCLONE_READ_ONLY:-false}"
  local rclone_bin="${NUCLEUS_RCLONE_BIN:-rclone}"

  local attempts="${NUCLEUS_MOUNT_ATTEMPTS:?}"
  local attach_seconds="${NUCLEUS_MOUNT_ATTACH_SECONDS:?}"

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
  # Set when the last attach wait ended on a mount table that could not be read.
  # Read by the per-attempt class below and by the exhaustion record, both of
  # which need to say "the read failed" rather than "the mount failed".
  local probe_unknown=false
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
    # WHY: backend_args emits ONE TOKEN PER LINE.  Passing "$(<file)" collapses that to a
    #   SINGLE argument, because double quotes suppress field splitting — rclone then
    #   receives one blob where it expects remote, mount point and flags as separate argv
    #   entries, and rejects it with its usage message.  Read the file line-by-line into an
    #   array instead: "${mount_args[@]}" passes each token as a discrete argument while
    #   preserving any token that itself contains a space, which matters because a mount
    #   point can live under a path containing spaces.  Empty lines are skipped rather than
    #   emitted as empty arguments.  (No mapfile: the interpreter is bash 3.2 on macOS.)
    local -a mount_args=()
    local _cm_arg_line
    while IFS= read -r _cm_arg_line; do
      if [ -n "$_cm_arg_line" ]; then
        mount_args+=("$_cm_arg_line")
      fi
    done <"$mount_args_file"
    backend_mount "$rclone_bin" "${mount_args[@]}"

    # Wait for the volume to appear.
    local attach_start=$SECONDS
    local live=false
    local probe_state=""
    # How the wait below ended, as opposed to what its last probe answered. The
    # two disagree whenever the loop breaks out on a dead child after a readable
    # absent answer, so the classification keys on this rather than inferring an
    # ending from probe_state.
    local exit_reason=""
    while [ $((SECONDS - attach_start)) -lt "$attach_seconds" ]; do
      # WHY: backend_probe_state, not backend_probe. The two-valued answer is 0
      #   both for a live mount and for a table that could not be read, and this
      #   loop acts on that 0 by recording the service running and deleting the
      #   evidence, so only the three-valued answer is safe here: an unknown
      #   state falls through to the same poll the absent state takes, spending
      #   no attempt and issuing no restart of its own, and the budget below is
      #   what ends the run.
      probe_state="$(backend_probe_state "$mount_point")"
      if [ "$probe_state" = present ]; then
        live=true
        exit_reason="attached"
        break
      fi
      # WHY: a mount that dies during startup would otherwise be polled for the
      #   whole budget -- 45s x 3 attempts in production -- before anything
      #   classified it, even though the capture file already held the reason.
      #   An unreaped child is a zombie and kill -0 succeeds on a zombie, but
      #   the probe and sleep below are themselves foreground children, so bash
      #   reaps between polls and the worst case is one extra poll, not the
      #   full budget.
      if ! kill -0 "${_backend_rclone_pid:-}" 2>/dev/null; then
        exit_reason="child-exited"
        break
      fi
      sleep 1
    done

    [ -n "$exit_reason" ] || exit_reason="budget"

    if [ "$live" = true ]; then
      # Mount succeeded — record and watch.
      # No generation bump here: the run token belongs to the supervisor, and the
      # watchdog records a restart from a change in it.  Advancing it on a
      # successful start would register a phantom restart on every mount.
      svc_health_set_running "$instance"
      svc_health_record_success "$instance"
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
    # WHY: an unreadable table says nothing about the mount. backend_class reads
    #   rclone's output and answers mount-failed when it finds no cause there,
    #   which would blame the mount for a read nobody could make and send the
    #   operator to check the remote. io-transient is the class whose remedy is
    #   to try again, so the unreadable answer overrides the classifier, and the
    #   override is keyed on how the wait ended rather than on probe_state, which
    #   on its own cannot tell a budget expiry from a child that died first.
    #
    # WHY: no `attached` arm, because the wait can only end attached when live
    #   is true, and the success path above exits at its own line before reaching
    #   this case. The arm below therefore matches no ending this function can
    #   produce, so an exit_reason that lands there is one of our own strings
    #   renamed or mistyped, and io-transient is the safe reading of a state
    #   this code cannot place: the class whose remedy is to try again, which
    #   costs a retry, over the terminal classes, which stop the run and point
    #   the operator at the remote on the strength of a read that never completed.
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

    # Kill the rclone process if still running.
    if [ -n "${_backend_rclone_pid:-}" ] && kill -0 "$_backend_rclone_pid" 2>/dev/null; then
      # check-suppress:suppression_doc: kill may fail if rclone already exited
      kill -TERM "$_backend_rclone_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: wait may fail if rclone already exited
      wait "$_backend_rclone_pid" 2>/dev/null || true
    fi

    notice -l cloud-drives "$instance: attempt $attempt failed (class=$class, $remedy)"

    # WHY: the capture file is dropped on every other path because the class in
    #   the health record is the whole diagnosis there. On the unreadable-table
    #   path the class is one this runner chose rather than one rclone's output
    #   supports, so the file is the only remaining record of what the mount was
    #   doing while the read kept failing. Kept and named rather than dropped
    #   silently; at most one file per attempt survives a run.
    if [ "$probe_unknown" = true ]; then
      notice -l cloud-drives "$instance: rclone output kept at $capture_file"
    else
      rm -f "$capture_file"
    fi
    rm -f "$mount_args_file"

    # Check if transient — terminal classes stop immediately.
    if ! backend_is_transient "$class"; then
      svc_health_set_blocked "$instance" "$class" "$remedy"
      exit 0
    fi

    # Transient — backoff and retry.
    if [ "$attempt" -lt "$attempts" ]; then
      local backoff
      backoff=$(_cm_get_backoff "$attempt")
      notice -l cloud-drives "$instance: retrying in ${backoff}s"
      sleep "$backoff"
    fi

    attempt=$((attempt + 1))
  done

  # Exhausted all attempts — write blocked record.
  # WHY: the last attempt's own diagnosis must not be overwritten. $class holds
  #   the last attempt's classification because the loop reassigns it on every
  #   pass, and no health record carries that classification out of the loop: a
  #   transient attempt writes no health record at all, and the capture file kept
  #   on the unreadable-table path holds rclone's raw output rather than a class,
  #   so substituting a hardcoded mount-failed here would discard the one
  #   classification the run produced — sending the operator to the remote when
  #   what stopped the run was the budget. Reading $class here is not a scope
  #   error: it is declared `local` inside the attempt loop above, and bash
  #   scopes `local` to the enclosing function rather than the block, so the
  #   name still resolves after the loop closes.
  #
  # WHY: a NUCLEUS_MOUNT_ATTEMPTS that is not a number leaves final_class empty
  #   rather than wrong — `[ 1 -le abc ]` fails, the loop body never runs, and
  #   `class` is never assigned. It is not reachable from a valid config:
  #   services.schema.json pins mountAttempts to a minimum of 1 and the
  #   schema-validation check step validates the file, so nothing here guards it.
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

# Run if executed directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cm_main "$@"
fi
