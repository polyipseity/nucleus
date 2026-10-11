# shellcheck shell=bash
# Mount backend for Linux: fuse3. Failures are classified by error text.

[ -n "${_NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED-}" ] && return
_NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED=1

_MOUNT_BACKEND_LINUX_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_MOUNT_BACKEND_LINUX_DIR/lib.sh"
# shellcheck source=service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_MOUNT_BACKEND_LINUX_DIR/service-health.sh"
# shellcheck source=svc-instances.sh
[ -n "${_NUCLEUS_SVC_INSTANCES_SOURCED-}" ] || . "$_MOUNT_BACKEND_LINUX_DIR/svc-instances.sh"

# Args: $1 stderr capture file path.
# Outputs: class token string, in decision order. One of: no-output,
#   io-transient, auth, remote-not-found, path-permission, torn-down,
#   mount-failed.
backend_class() {
  local capture="$1"
  # A missing file and a file rclone wrote nothing into are the same silence:
  # the runner reaches classification with no rclone words to justify any
  # class, and the old mount-failed fall-through blamed the remote anyway.
  if [ ! -f "$capture" ] || [ ! -s "$capture" ]; then
    printf 'no-output\n'
    return
  fi

  if grep -qE 'fusermount.*failed|fuse.*not found|/dev/fuse.*no such' "$capture"; then
    printf 'io-transient\n'
    return
  fi

  # WHY anchored to an HTTP status: same as darwin, a bare `401` matched the
  #   millisecond field of an rclone timestamp and recorded a healthy remote as
  #   bad credentials. 421 is anchored for the same reason: an expired session
  #   surfaces as HTTP 421, and a bare number would match that millisecond
  #   field too. Cross-host parity: both classifiers decide the same class from
  #   the same wording.
  if grep -qE 'Unauthorized|Invalid credentials|unauthorized_request|auth.*failed|HTTP status 401|HTTP status 421|Invalid global session' "$capture"; then
    printf 'auth\n'
    return
  fi

  if grep -qE 'not found|does not exist|Unknown remote|could not list files|directory not found' "$capture"; then
    printf 'remote-not-found\n'
    return
  fi

  if grep -qE 'permission denied|operation not permitted|access denied|No such file or directory' "$capture"; then
    printf 'path-permission\n'
    return
  fi

  if grep -qE 'connection refused|connection reset|timeout|resource temporarily unavailable|device or resource busy' "$capture"; then
    printf 'io-transient\n'
    return
  fi

  # WHY after every error grep: same as darwin, a capture holding a real error
  #   plus the clean-unmount NOTICE is the error case, and each grep above
  #   returns before this one is reached. rclone logs `Unmounted rclone mount`
  #   when a mounted volume is torn down cleanly and writes nothing else on
  #   that path, so reaching here with the NOTICE is the signature of a
  #   teardown: the volume attached and something removed it, and no remote,
  #   credential, or path is at fault. Cross-host parity: both classifiers
  #   decide the same class from the same wording.
  if grep -q 'Unmounted rclone mount' "$capture"; then
    printf 'torn-down\n'
    return
  fi

  printf 'mount-failed\n'
}

backend_remedy() {
  local class="$1"
  case "$class" in
  io-transient) printf 'retry in progress' ;;
  auth) printf 'verify remote credentials' ;;
  remote-not-found) printf 'check remote name and configuration' ;;
  path-permission) printf 'check mount point permissions' ;;
  torn-down) printf "%s" "the mount attached and was torn down; check the runner log and system logs for the teardown cause" ;;
  no-output) printf "%s" "rclone wrote nothing to its output; check the runner log for this mount" ;;
  *) printf "%s" "check remote configuration and credentials; when present, the health record for this mount carries rclone's failing output" ;;
  esac
}

backend_is_transient() {
  local class="$1"
  case "$class" in
  io-transient) return 0 ;;
  esac
  return 1
}

backend_prepare() {
  local instance="$1"

  if [ ! -e /dev/fuse ]; then
    if command -v modprobe >/dev/null 2>&1; then
      # check-suppress:suppression_doc: best-effort modprobe; may fail on non-modular kernels
      modprobe fuse 2>/dev/null || true
    fi
    if [ ! -e /dev/fuse ]; then
      svc_health_set_blocked "$instance" "io-transient" "fuse module not loaded; run modprobe fuse"
      return 20
    fi
  fi

  if ! command -v fusermount3 >/dev/null 2>&1; then
    svc_health_set_blocked "$instance" "mount-failed" "fusermount3 not found; install fuse3"
    return 20
  fi

  return 0
}

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

backend_mount() {
  local rclone_bin="$1"
  shift
  "$rclone_bin" mount "$@" 2>"$_backend_capture" &
  _backend_rclone_pid=$!
}

_backend_capture=""
_backend_rclone_pid=""

# backend_probe_state: the mount table's three-valued answer for a mount point.
# Args: $1: mount point.
# Prints: present, absent:<reason> or unknown:<reason>. Always returns 0.
# WHY: the question is MOUNT STATE, never directory contents. An empty remote
#   root is a legitimate state, so a content test reports a healthy mount as
#   dead and the service stays blocked at `mount-failed` on a mount that
#   succeeded.
# WHY: three values, because a two-valued predicate answers "live" for a table
#   that could not be read, and a caller would then act on a volume it could not
#   disprove.
# WHY: delegating keeps one implementation. Every mount-state caller on this
#   platform answers through svc_mount_table_state, so none can disagree.
backend_probe_state() {
  svc_mount_table_state "$1"
}

backend_unmount() {
  local mount_point="$1"
  # check-suppress:suppression_doc: best-effort unmount; fusermount may fail if nothing is mounted
  fusermount3 -u "$mount_point" 2>/dev/null || true
}

# backend_provider_refusal: always false on Linux (no FSKit/extension concept).
backend_provider_refusal() {
  return 1
}
