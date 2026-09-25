# shellcheck shell=bash
# Mount backend for Linux: fuse3.
# Implements the backend_* interface for the cloud-mount core runner.
#
# No filesystem extension concept — all failures are classified by error text.
#
# Usage:
#   . "$SCRIPT_DIR/../lib/mount-backend-linux.sh"

[ -n "${_NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED-}" ] && return
_NUCLEUS_MOUNT_BACKEND_LINUX_SOURCED=1

_MOUNT_BACKEND_LINUX_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_MOUNT_BACKEND_LINUX_DIR/lib.sh"
# shellcheck source=service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_MOUNT_BACKEND_LINUX_DIR/service-health.sh"
# shellcheck source=svc-instances.sh
[ -n "${_NUCLEUS_SVC_INSTANCES_SOURCED-}" ] || . "$_MOUNT_BACKEND_LINUX_DIR/svc-instances.sh"

# backend_class — classify a failure from stderr capture.
backend_class() {
  local capture="$1"
  [ -f "$capture" ] || {
    printf 'mount-failed\n'
    return
  }

  if grep -qE 'fusermount.*failed|fuse.*not found|/dev/fuse.*no such' "$capture"; then
    printf 'io-transient\n'
    return
  fi

  if grep -qE 'Unauthorized|Invalid credentials|unauthorized_request|auth.*failed|401' "$capture"; then
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

  printf 'mount-failed\n'
}

# backend_remedy — return the remedy text for a class.
backend_remedy() {
  local class="$1"
  case "$class" in
  io-transient) printf 'retry in progress' ;;
  auth) printf 'verify remote credentials' ;;
  remote-not-found) printf 'check remote name and configuration' ;;
  path-permission) printf 'check mount point permissions' ;;
  *) printf 'check remote configuration and credentials' ;;
  esac
}

# backend_is_transient — return 0 if the class is transient (retryable).
backend_is_transient() {
  local class="$1"
  case "$class" in
  io-transient) return 0 ;;
  esac
  return 1
}

# backend_prepare — ensure fuse3 is available.
backend_prepare() {
  local instance="$1"

  # Check if fuse module is loaded.
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

  # Verify fusermount3 is available.
  if ! command -v fusermount3 >/dev/null 2>&1; then
    svc_health_set_blocked "$instance" "mount-failed" "fusermount3 not found; install fuse3"
    return 20
  fi

  return 0
}

# backend_args — emit Linux-specific rclone mount flags.
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

# backend_mount — invoke rclone.
backend_mount() {
  local rclone_bin="$1"
  shift
  "$rclone_bin" mount "$@" 2>"$_backend_capture" &
  _backend_rclone_pid=$!
}

_backend_capture=""
_backend_rclone_pid=""

# backend_probe — report whether the mount point is a LIVE MOUNT.
# Args: $1 — mount_point.
# Exit: 0 when mounted, 1 when not mounted.
#
# WHY: this asks about MOUNT STATE, never about directory contents. An empty
#   remote root is a legitimate state (a freshly created cloud folder), so a
#   content test reports a healthy mount as dead: the runner never sets live,
#   retries `mountAttempts` times, and leaves the service permanently blocked at
#   `mount-failed` on a mount that actually succeeded.
# This is the same PREDICATE the macOS backend asks via diskutil — "is this path
#   a live mount?" — answered here with this host's mount state, through the
#   repository's single mount-table predicate: svc_mount_table_contains
#   (src/scripts/lib/svc-instances.sh). Delegating rather than re-parsing keeps
#   one implementation of the question, so `nucleus-cloud repair` and this probe
#   can never disagree about whether a mount point is mounted.
backend_probe() {
  svc_mount_table_contains "$1"
}

# backend_unmount — release the volume.
backend_unmount() {
  local mount_point="$1"
  # check-suppress:suppression_doc: best-effort unmount; fusermount may fail if nothing is mounted
  fusermount3 -u "$mount_point" 2>/dev/null || true
}

# backend_repair — unmount and remount.
backend_repair() {
  local mount_point="${1:-}"
  if [ -n "$mount_point" ]; then
    printf 'Unmounting %s...\n' "$mount_point"
    # check-suppress:suppression_doc: best-effort unmount during repair
    fusermount3 -u "$mount_point" 2>/dev/null || true
  fi
  printf 'Mount will be retried on next watchdog tick.\n'
}

# backend_provider_refusal — always false on Linux (no FSKit/extension concept).
backend_provider_refusal() {
  return 1
}
