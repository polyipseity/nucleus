# shellcheck shell=bash
# Mount backend for macOS: macFUSE/FSKit. Every FSKit/macFUSE specific lives here,
# so the core runner never mentions them.
# ref: https://github.com/macfuse/macfuse/issues/1132

[ -n "${_NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED-}" ] && return
_NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED=1

_MOUNT_BACKEND_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/lib.sh"
# shellcheck source=macos-fskit.sh
[ -n "${_NUCLEUS_MACOS_FSKIT_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/macos-fskit.sh"
# shellcheck source=service-health.sh
[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] || . "$_MOUNT_BACKEND_DIR/service-health.sh"

# Args: $1 stderr capture file path.
# Outputs: class token string. One of: provider-refusal, provider-version,
#   io-transient, auth, remote-not-found, path-permission, mount-failed.
backend_class() {
  local capture="$1"
  [ -f "$capture" ] || {
    printf 'mount-failed\n'
    return
  }

  # fskit_macfuse_module_state answers enabled|disabled|unknown. `disabled` means the
  # extension is present but switched off, which a re-enable can clear, so it is the one
  # provider state worth retrying. Anything else is a module that was listed and failed
  # anyway, or a state nobody could read, and a retry clears neither. Retrying provider
  # failures is what produced the restart storm.
  # WHY no macFUSE version check here: backend_prepare blocks provider-version up front
  # when the installed macFUSE predates the FSKit volume-operation APIs, so reaching here
  # with `enabled` means a listed module whose mount still failed.
  if grep -qE 'File system extension not (found|enabled)|fuse: mount failed with error|mount\(8\) returned 69|MFMount.*not enabled' "$capture"; then
    if [ "$(fskit_macfuse_module_state)" = "disabled" ]; then
      printf 'provider-refusal\n'
    else
      printf 'provider-version\n'
    fi
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

  if grep -qE 'permission denied|operation not permitted|access denied|mount point.*not a directory|No such file or directory' "$capture"; then
    printf 'path-permission\n'
    return
  fi

  if grep -qE 'connection refused|connection reset|timeout|resource temporarily unavailable|device or resource busy' "$capture"; then
    printf 'io-transient\n'
    return
  fi

  printf 'mount-failed\n'
}

# Args: $1 class token.
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

# Return 0 if the class is transient (retryable).
backend_is_transient() {
  local class="$1"
  case "$class" in
  provider-refusal | io-transient) return 0 ;;
  esac
  return 1
}

# Return 0 if $1 >= $2 (dot-separated semver).
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

# The only place that registers/re-registers the filesystem extension.
# Args: $1 instance key. Returns 20 for user action required.
backend_prepare() {
  local instance="$1"

  local macfuse_bin="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
  if [ ! -x "$macfuse_bin" ]; then
    macfuse_bin="/opt/homebrew/bin/macfuse"
    if [ ! -x "$macfuse_bin" ]; then
      svc_health_set_blocked "$instance" "provider-version" "macFUSE not installed; install via 'brew install --cask macfuse@dev'"
      return 20
    fi
  fi

  # WHY: FSKit volume operations need macFUSE 5.4.0+ on macOS 27. Earlier versions lack
  # the FSKit daemon interface, and this check stops a stale install failing silently.
  local installed_version
  installed_version=$("$macfuse_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
  if ! _macfuse_version_gte "$installed_version" "5.4.0"; then
    svc_health_set_blocked "$instance" "provider-version" "macFUSE $installed_version is too old for FSKit; upgrade to 5.4.0+"
    return 20
  fi

  # WHY: never --force per attempt. This only runs when the extension is off.
  if ! fskit_extension_is_enabled; then
    # check-suppress:suppression_doc: best-effort re-registration; failure blocks the mount
    /opt/homebrew/bin/brew install --cask --no-quarantine macfuse@dev 2>/dev/null || true
  fi

  local module_state
  module_state="$(fskit_macfuse_module_state)"
  case "$module_state" in
  enabled)
    return 0
    ;;
  disabled)
    svc_health_set_blocked "$instance" "provider-refusal" "$(backend_remedy provider-refusal)"
    return 20
    ;;
  unknown)
    # WHY this fails OPEN while backend_class fails CLOSED for the same `unknown`: they
    # answer different questions. prepare asks "may I proceed?", so refusing would block a
    # mount that may work, under a class that misdescribes it. class asks "what kind of
    # failure is this?", and a provider failure nobody can explain is not something a retry
    # clears. Composed, they attempt once, then block. Do not make either match the other.
    return 0
    ;;
  esac

  # An unexpected value fails OPEN like `unknown`: the mount is attempted and rclone
  # plus backend_class report the real failure.
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

  # FSKit backend args, macOS 27+.
  printf '%s\n' "-obackend=fskit"

  if [ -n "$extra_args" ]; then
    printf '%s\n' "$extra_args"
  fi
}

# Args: $1 rclone binary path, remaining args mount flags (from backend_args).
backend_mount() {
  local rclone_bin="$1"
  shift
  "$rclone_bin" mount "$@" 2>"$_backend_capture" &
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

  # WHY: a diskutil that names no volume answers not mounted. Falling through to the
  # directory test would read leftover files in a mount point as an attached volume, and
  # the attach loop acts on `present` by recording the service running and deleting the
  # capture file. A diskutil that cannot answer reads the same, so it too answers absent,
  # and unknown:dir-unreadable stays reserved for a caller-unreadable directory on a host
  # with no diskutil.
  if command -v diskutil >/dev/null 2>&1; then
    if diskutil info "$mount_point" 2>/dev/null | grep -q "Volume Name"; then
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

# Args: $1 instance key (optional, for health record).
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

# Args: $1 stderr capture file.
backend_provider_refusal() {
  local capture="$1"
  [ -f "$capture" ] || return 1
  grep -qE 'File system extension not (found|enabled)|fuse: mount failed with error|mount\(8\) returned 69|MFMount.*not enabled' "$capture"
}
