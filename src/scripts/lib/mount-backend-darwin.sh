# shellcheck shell=bash
# Mount backend for macOS: rclone nfsmount over rclone's own local NFS server.
# Every macOS-mount-specific decision lives here, so the core runner never
# mentions them.
# WHY nfsmount and not the FUSE mount: live diagnostics on macOS 27 showed
#   fskitd's mount preflight rejecting these mount points with
#   NSCocoaErrorDomain 516 milliseconds after the FUSE handshake, and rclone
#   reporting the rejected volume as a clean unmount and exit 0, which hid the
#   cause from every log-based diagnosis. nfsmount needs no file system
#   extension at all and is the backend rclone documents for macOS.

[ -n "${_NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED-}" ] && return
_NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED=1

_MOUNT_BACKEND_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/lib.sh"
# shellcheck source=service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/service-health.sh"

# Args: $1 stderr capture file path.
# Outputs: class token string, in decision order. One of: no-output, auth,
#   remote-not-found, path-permission, io-transient, torn-down, mount-failed.
backend_class() {
  local capture="$1"
  # A missing file and a file rclone wrote nothing into are the same silence:
  # the runner reaches classification with no rclone words to justify any
  # class, and the old mount-failed fall-through blamed the remote anyway.
  if [ ! -f "$capture" ] || [ ! -s "$capture" ]; then
    printf 'no-output\n'
    return
  fi

  # WHY anchored to an HTTP status: a bare `401` also matched the millisecond
  #   field of an rclone timestamp (12:58:41.401), so an ordinary mount failure
  #   was recorded as bad credentials. Genuine auth errors carry either the
  #   word Unauthorized (already matched above) or the status phrase itself.
  # WHY 421 is anchored the same way: an expired session surfaces as HTTP 421,
  #   and 421 lands in the millisecond field of that same timestamp dozens of
  #   times a second, so a bare number would recreate the 401 bug one digit
  #   over. The session wording is a phrase, not a number, so it needs no
  #   anchor, and it is what an expired Apple iCloud session reports.
  if grep -qE 'Unauthorized|Invalid credentials|unauthorized_request|auth.*failed|HTTP status 401|HTTP status 421|Invalid global session' "$capture"; then
    printf 'auth\n'
    return
  fi

  if grep -qE 'not found|does not exist|Unknown remote|could not list files|directory not found' "$capture"; then
    printf 'remote-not-found\n'
    return
  fi

  if grep -qE 'permission denied|operation not permitted|access denied|mount point.*not a directory|No such file or directory' "$capture"; then
    printf 'path-permission\n'
    return
  fi

  # WHY failed to mount NFS volume: nfsmount reports a mount the kernel refused
  #   (the path still owned by an earlier attempt) with that line, and only a
  #   retry re-grants it; the terminal mount-failed would block instead.
  if grep -qE 'connection refused|connection reset|timeout|resource temporarily unavailable|device or resource busy|failed to mount NFS volume' "$capture"; then
    printf 'io-transient\n'
    return
  fi

  # WHY after every error grep: a capture holding a real error plus the
  #   clean-unmount NOTICE is the error case, and each grep above returns
  #   before this one is reached. rclone logs `Unmounted rclone mount` when a
  #   mounted volume is torn down cleanly and writes nothing else on that
  #   path, so reaching here with the NOTICE is the signature of a teardown:
  #   the volume attached and something removed it, and no remote,
  #   credential, or path is at fault.
  if grep -q 'Unmounted rclone mount' "$capture"; then
    printf 'torn-down\n'
    return
  fi

  printf 'mount-failed\n'
}

# Args: $1 class token.
backend_remedy() {
  local class="$1"
  case "$class" in
  auth)
    printf 'verify remote credentials'
    ;;
  remote-not-found)
    printf 'check remote name and configuration'
    ;;
  path-permission)
    printf 'check mount point permissions'
    ;;
  io-transient)
    printf 'retry in progress'
    ;;
  torn-down)
    printf "%s" "the mount attached and was torn down; check the runner log and system logs for the teardown cause"
    ;;
  no-output)
    printf "%s" "rclone wrote nothing to its output; check the runner log for this mount"
    ;;
  *)
    printf "%s" "check remote configuration and credentials; when present, the health record for this mount carries rclone's failing output"
    ;;
  esac
}

# Return 0 if the class is transient (retryable).
backend_is_transient() {
  local class="$1"
  case "$class" in
  io-transient) return 0 ;;
  esac
  return 1
}

# Args: $1 instance key. Returns 20 for user action required, writing the
# blocked record itself; 0 when this host can run the backend.
backend_prepare() {
  local instance="$1"
  local rclone_bin="${NUCLEUS_RCLONE_BIN:-rclone}"

  if ! rclone_bin="$(command -v "$rclone_bin")"; then
    svc_health_set_blocked "$instance" "mount-backend-unsupported" "rclone is not on PATH; the managed profile provides it, so rebuild the profile and log in again"
    return 20
  fi

  # WHY `nfsmount --help` and not `help nfsmount`: rclone's help command exits
  #   0 for any topic, including ones that do not exist, so it cannot separate
  #   a build with nfsmount from one without it. The subcommand's own --help
  #   fails when the subcommand is missing.
  if ! "$rclone_bin" nfsmount --help >/dev/null 2>&1; then
    svc_health_set_blocked "$instance" "mount-backend-unsupported" "the rclone on PATH has no nfsmount command; the managed profile pins a version that has it, so rebuild the profile and log in again"
    return 20
  fi

  return 0
}

# Args: $1 remote, $2 mount_point, $3 read_only ("true"/"false"), $4 extra_args
# (newline-separated).
backend_args() {
  local remote="$1" mount_point="$2" read_only="$3" extra_args="$4"

  printf '%s\n' "$remote"
  printf '%s\n' "$mount_point"
  printf '%s\n' "--vfs-cache-mode"
  printf '%s\n' "full"
  printf '%s\n' "--vfs-cache-max-age"
  printf '%s\n' "1h"
  printf '%s\n' "--dir-cache-time"
  printf '%s\n' "5m"
  printf '%s\n' "--poll-interval"
  printf '%s\n' "1m"
  printf '%s\n' "--log-level"
  printf '%s\n' "NOTICE"

  if [ "$read_only" = "true" ]; then
    printf '%s\n' "--read-only"
  fi

  if [ -n "$extra_args" ]; then
    printf '%s\n' "$extra_args"
  fi
}

# Args: $1 rclone binary path, remaining args mount flags (from backend_args).
# WHY nfsmount: chosen here so the runner stays free of macOS-mount specifics;
#   the diagnostics behind the choice are in the file header.
backend_mount() {
  local rclone_bin="$1"
  shift
  "$rclone_bin" nfsmount "$@" 2>"$_backend_capture" &
  _backend_rclone_pid=$!
}

# Stderr capture file for the current attempt.
_backend_capture=""
_backend_rclone_pid=""

# Args: $1 mount point.
# Prints: present, absent:not-listed or unknown:dir-unreadable. Always returns 0.
# WHY: the question is mount state and diskutil decides it. Only a host with no
#   diskutil falls back to the directory test.
# WHY: the reason after the prefix is this platform's own. The attach loop in
#   rclone-mount.sh tests the prefix alone, and the Linux reasons name a reader's
#   status and a bound, so reusing one here would give one token two meanings.
backend_probe_state() {
  local mount_point="$1"

  # WHY the reported mount point is the only evidence, and a volume name is none: a
  # poisoned mount point, meaning a directory whose mount was torn down uncleanly, has
  # diskutil resolve the path to the CONTAINING APFS volume, so it prints a real
  # `Volume Name: Data` and a `Mount Point:` of /System/Volumes/Data. Grepping for the
  # volume name alone answered `present` for exactly that state, and the attach loop in
  # rclone-mount.sh acts on `present` by recording the service running and deleting the
  # capture file, so a dead mount was recorded healthy and its evidence destroyed in the
  # same step. A poisoned mount point also stays poisoned across a reboot with nothing
  # mounted, so the wrong answer recurred and spread to other drives. Only a reported
  # mount point equal to the path we passed proves the volume is attached HERE.
  # WHY absent when no line matches, and unknown is not used: a diskutil that names no
  # volume and one that fails to answer both print no `Mount Point:` line, and neither is
  # evidence of a mount. unknown:dir-unreadable stays reserved for a caller-unreadable
  # directory on a host with no diskutil, so the token keeps one meaning.
  if command -v diskutil >/dev/null 2>&1; then
    local reported
    reported="$(diskutil info "$mount_point" 2>/dev/null |
      sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p' |
      head -n 1)"
    if [ "$reported" = "$mount_point" ]; then
      printf 'present\n'
    else
      printf 'absent:not-listed\n'
    fi
    return 0
  fi

  if [ ! -d "$mount_point" ]; then
    printf 'absent:not-listed\n'
    return 0
  fi

  # WHY: an unreadable directory lists as empty, so only ls's own exit status
  #   tells a volume this caller may not read from one that is empty.
  local listing=""
  if ! listing="$(ls -A "$mount_point" 2>/dev/null)"; then
    printf 'unknown:dir-unreadable\n'
    return 0
  fi
  if [ -n "$listing" ]; then
    printf 'present\n'
  else
    printf 'absent:not-listed\n'
  fi
  return 0
}

# Args: $1 mount_point.
backend_unmount() {
  local mount_point="$1"
  if command -v diskutil >/dev/null 2>&1; then
    # check-suppress:suppression_doc: best-effort unmount; outcome checked via mount table below
    diskutil unmount force "$mount_point" 2>/dev/null || true
  elif command -v fusermount3 >/dev/null 2>&1; then
    # check-suppress:suppression_doc: best-effort unmount; fusermount may fail if nothing is mounted
    fusermount3 -u "$mount_point" 2>/dev/null || true
  fi
}
