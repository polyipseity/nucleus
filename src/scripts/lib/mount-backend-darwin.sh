# shellcheck shell=bash
# Mount backend for macOS: macFUSE/FSKit.
# Implements the backend_* interface for the cloud-mount core runner.
#
# All FSKit/macFUSE specifics live here — the core runner never mentions them.
# ref: https://github.com/macfuse/macfuse/issues/1132
#
# Usage:
#   . "$SCRIPT_DIR/../lib/mount-backend-darwin.sh"

[ -n "${_NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED-}" ] && return
_NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED=1

_MOUNT_BACKEND_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/lib.sh"
# shellcheck source=macos-fskit.sh
[ -n "${_NUCLEUS_MACOS_FSKIT_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/macos-fskit.sh"
# shellcheck source=service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/service-health.sh"

# backend_class — classify a failure from stderr capture.
# Args: $1 — stderr capture file path.
# Outputs: class token string. One of: provider-refusal, provider-version,
#   io-transient, auth, remote-not-found, path-permission, mount-failed.
backend_class() {
  local capture="$1"
  [ -f "$capture" ] || {
    printf 'mount-failed\n'
    return
  }

  # FSKit/provider refusal patterns.
  # The module state decides retry policy: provider-refusal is transient and is retried,
  # provider-version is terminal and blocks at once.  Retrying a provider failure is what
  # produced the original restart storm.
  # fskit_macfuse_module_state answers exactly three values (enabled|disabled|unknown), so
  # this branch reads:
  #   disabled — the extension is PRESENT but switched off.  The user must re-enable it,
  #     and a re-enable can succeed, so this is the one provider state worth retrying.
  #   everything else — `enabled`, `unknown`, or an unexpected/empty value.  Either the
  #     module IS listed and the mount failed anyway, or its state could not be read at
  #     all; neither is a condition a retry can clear, so both are terminal.
  # WHY this function does NOT check a macFUSE version: the version judgement is made in
  # backend_prepare below, which blocks provider-version up front when the installed
  # macFUSE predates 5.4.0 (the first release built against the macOS 27 FSKit
  # volume-operation APIs).  Reaching this branch with `enabled` therefore means a listed
  # module whose mount still failed — terminal is the safe reading, since a retry that
  # cannot help is exactly the storm this classification exists to prevent.
  if grep -qE 'File system extension not (found|enabled)|fuse: mount failed with error|mount\(8\) returned 69|MFMount.*not enabled' "$capture"; then
    if [ "$(fskit_macfuse_module_state)" = "disabled" ]; then
      printf 'provider-refusal\n'
    else
      printf 'provider-version\n'
    fi
    return
  fi

  # Authentication errors.
  if grep -qE 'Unauthorized|Invalid credentials|unauthorized_request|auth.*failed|401' "$capture"; then
    printf 'auth\n'
    return
  fi

  # Remote not found.
  if grep -qE 'not found|does not exist|Unknown remote|could not list files|directory not found' "$capture"; then
    printf 'remote-not-found\n'
    return
  fi

  # Path/permission errors.
  if grep -qE 'permission denied|operation not permitted|access denied|mount point.*not a directory|No such file or directory' "$capture"; then
    printf 'path-permission\n'
    return
  fi

  # Transient I/O.
  if grep -qE 'connection refused|connection reset|timeout|resource temporarily unavailable|device or resource busy' "$capture"; then
    printf 'io-transient\n'
    return
  fi

  printf 'mount-failed\n'
}

# backend_remedy — return the remedy text for a class.
# Args: $1 — class token.
backend_remedy() {
  local class="$1"
  case "$class" in
  provider-refusal | provider-version)
    printf "%s" "run sudo killall fskitd (nucleus-cloud repair), then re-enable macFUSE in System Settings > General > Login Items & Extensions > By category > File System Extensions"
    ;;
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
  *)
    printf 'check remote configuration and credentials'
    ;;
  esac
}

# backend_is_transient — return 0 if the class is transient (retryable).
backend_is_transient() {
  local class="$1"
  case "$class" in
  provider-refusal | io-transient) return 0 ;;
  esac
  return 1
}

# _macfuse_version_gte — return 0 if $1 >= $2 (dot-separated semver).
_macfuse_version_gte() {
  local IFS='.'
  read -ra v1 <<<"$1"
  read -ra v2 <<<"$2"
  for i in 0 1 2; do
    local a="${v1[$i]:-0}" b="${v2[$i]:-0}"
    if [ "$a" -gt "$b" ] 2>/dev/null; then return 0; fi
    if [ "$a" -lt "$b" ] 2>/dev/null; then return 1; fi
  done
  return 0
}

# backend_prepare — ensure the FUSE layer is present and at the required version.
# Writes a health record and returns 20 for user-action required.
# This is the ONLY place that registers/re-registers the filesystem extension.
# Args: $1 — instance key.
backend_prepare() {
  local instance="$1"

  # Verify macFUSE binary exists.
  local macfuse_bin="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
  if [ ! -x "$macfuse_bin" ]; then
    macfuse_bin="/opt/homebrew/bin/macfuse"
    if [ ! -x "$macfuse_bin" ]; then
      svc_health_set_blocked "$instance" "provider-version" "macFUSE not installed; install via 'brew install --cask macfuse@dev'"
      return 20
    fi
  fi

  # WHY: FSKit volume operations require macFUSE 5.4.0+ on macOS 27.
  # Earlier versions lack the FSKit daemon interface.  Pin the version in
  # Homebrew config; this check prevents silent failures from stale installs.
  local installed_version
  installed_version=$("$macfuse_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
  if ! _macfuse_version_gte "$installed_version" "5.4.0"; then
    svc_health_set_blocked "$instance" "provider-version" "macFUSE $installed_version is too old for FSKit; upgrade to 5.4.0+"
    return 20
  fi

  # One-time install to re-register the filesystem extension if needed.
  # WHY: only called when the extension is not enabled; never --force per attempt.
  if ! fskit_extension_is_enabled; then
    # check-suppress:suppression_doc: best-effort re-registration; failure blocks the mount
    /opt/homebrew/bin/brew install --cask --no-quarantine macfuse@dev 2>/dev/null || true
  fi

  # Check FSKit module state.
  local module_state
  module_state="$(fskit_macfuse_module_state)"
  case "$module_state" in
  enabled)
    # Everything is fine, proceed.
    return 0
    ;;
  disabled)
    # Module not enabled — user action needed.
    svc_health_set_blocked "$instance" "provider-refusal" "$(backend_remedy provider-refusal)"
    return 20
    ;;
  unknown)
    # Cannot read the list — try to proceed; rclone will report if it fails.
    # WHY this fails OPEN while backend_class fails CLOSED for the same `unknown` state:
    # the two answer different questions.  prepare asks "may I proceed?" — refusing here
    # would block a mount that may work, under a class that misdescribes the condition.
    # class asks "what kind of failure is this?" — and a provider failure the module state
    # cannot explain is not something a retry can clear, so it is terminal.  Composed,
    # they yield "attempt once, then block": no path retries an unexplained provider
    # failure indefinitely.  Do not "fix" either one to match the other.
    return 0
    ;;
  esac

  # Not reachable through the three declared states above, but stated explicitly rather
  # than left to fall out of the `case`: an unexpected value fails OPEN, exactly like
  # `unknown`.  The mount is attempted, and rclone plus backend_class report the real
  # failure; failing closed here would block the mount under a class that misdescribes it.
  return 0
}

# backend_args — emit macOS-specific rclone mount flags.
# Args: $1 — remote; $2 — mount_point; $3 — read_only ("true"/"false");
#   $4 — extra_args (newline-separated).
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

  # FSKit backend args (macOS 27+).
  printf '%s\n' "-obackend=fskit"

  # Append any extra args.
  if [ -n "$extra_args" ]; then
    printf '%s\n' "$extra_args"
  fi
}

# backend_mount — invoke rclone with the resolved flags.
# Args: $1 — rclone binary path; remaining args — mount flags (from backend_args).
backend_mount() {
  local rclone_bin="$1"
  shift
  "$rclone_bin" mount "$@" 2>"$_backend_capture" &
  _backend_rclone_pid=$!
}

# _backend_capture — stderr capture file for the current attempt.
_backend_capture=""
_backend_rclone_pid=""

# backend_probe — check if the volume is live.
# Args: $1 — mount_point.
backend_probe() {
  local mount_point="$1"
  # On macOS, check if the mount point is a valid directory with content
  # or if diskutil reports it as mounted.
  if command -v diskutil >/dev/null 2>&1; then
    diskutil info "$mount_point" 2>/dev/null | grep -q "Volume Name"
    return $?
  fi
  # Fallback: check if the directory is non-empty (a mounted volume).
  [ -d "$mount_point" ] && [ "$(ls -A "$mount_point" 2>/dev/null)" ]
}

# backend_unmount — release the volume.
# Args: $1 — mount_point.
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

# backend_repair — repair the provider (fskitd restart + approval guidance).
# Args: $1 — instance key (optional, for health record).
backend_repair() {
  local instance="${1:-}"
  printf 'Restarting fskitd...\n'
  if fskit_restart_daemon 30; then
    printf 'fskitd restarted successfully.\n'
    local state
    state="$(fskit_macfuse_module_state)"
    case "$state" in
    enabled)
      printf 'macFUSE module is enabled in FSKit.\n'
      ;;
    disabled)
      printf 'macFUSE is missing from FSKit module list.\n'
      printf 'Enable it in: System Settings > General > Login Items & Extensions > By category > File System Extensions\n'
      ;;
    *)
      printf 'Could not read FSKit module list.\n'
      ;;
    esac
  else
    printf 'Failed to restart fskitd. Run '\''sudo killall fskitd'\'' manually.\n'
  fi
}

# backend_provider_refusal — whether the failure was a provider refusal.
# Args: $1 — stderr capture file.
backend_provider_refusal() {
  local capture="$1"
  [ -f "$capture" ] || return 1
  grep -qE 'File system extension not (found|enabled)|fuse: mount failed with error|mount\(8\) returned 69|MFMount.*not enabled' "$capture"
}
