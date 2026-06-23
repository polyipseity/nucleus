# shellcheck shell=sh
# Source this at the top of nucleus POSIX shell scripts after setting SCRIPT_DIR.
# Provides shared functions (usage_std, resolve_nucleus_root).
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../src/scripts/lib.sh"
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Repository root path. Falls back to git detection if unset.

# usage_std — Emit standardized usage text and exit.
usage_std() {
  _us_name="$1"
  _us_opts="${2:-}"
  shift 2 2>/dev/null || true

  printf 'usage: %s %s\n' "$_us_name" "$_us_opts"
  if [ "$#" -gt 0 ]; then
    printf '  %s\n' "$1"
  fi
}

# Resolution order: NUCLEUS_REPO_ROOT env var, then git rev-parse.
resolve_nucleus_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
    printf '%s\n' "$NUCLEUS_REPO_ROOT"
    return 0
  fi
  if command -v git >/dev/null 2>&1; then
    _nrr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    if [ -n "${_nrr_git_root:-}" ] && [ -d "$_nrr_git_root" ]; then
      printf '%s\n' "$_nrr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "resolve_nucleus_root: NUCLEUS_REPO_ROOT is not set or does not point to a directory" >&2
  return 1
}

# Resolution order: NUCLEUS_HOST env var, then uname auto-detection.
resolve_nucleus_host() {
  if [ -n "${NUCLEUS_HOST:-}" ]; then
    printf '%s\n' "$NUCLEUS_HOST"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "MacBook" ;;
    Linux)  printf '%s\n' "NixOS" ;;
    *)      printf '%s\n' "Unknown" ;;
  esac
}

merge_nix_config() {
  _mnc_features="${1:-experimental-features = nix-command flakes}"
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "$_mnc_features"
  else
    printf '%s' "$_mnc_features"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    exit 1
  fi
}

# sha256_of_file — Compute SHA-256 hex digest of a file.
#
# Usage: sha256_of_file file_path
#
# Tries sha256sum, then shasum -a 256, then openssl dgst -sha256.
# Calls require_command if no tool is available.
#
# Arguments:
#   file_path  Path to the file to hash.
sha256_of_file() {
  _sof_file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$_sof_file" | awk '{ print $1 }'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$_sof_file" | awk '{ print $1 }'
    return
  fi

  require_command openssl
  openssl dgst -sha256 "$_sof_file" | awk '{ print $2 }'
}

# nucleus_log_dir — Print the user-level log directory path.
#
# Platform-aware: returns the correct path for macOS vs Linux.
# Environment override: NUCLEUS_LOG_DIR
nucleus_log_dir() {
  if [ -n "${NUCLEUS_LOG_DIR:-}" ]; then
    printf '%s\n' "$NUCLEUS_LOG_DIR"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "${HOME}/Library/Logs/nucleus" ;;
    Linux)  printf '%s\n' "${HOME}/.local/state/nucleus/log" ;;
    *)      printf '%s\n' "${HOME}/.local/state/nucleus/log" ;;
  esac
}

# nucleus_system_log_dir — Print the system-level log directory path.
#
# Platform-aware: returns the correct path for macOS vs Linux.
# Environment override: NUCLEUS_SYSTEM_LOG_DIR
nucleus_system_log_dir() {
  if [ -n "${NUCLEUS_SYSTEM_LOG_DIR:-}" ]; then
    printf '%s\n' "$NUCLEUS_SYSTEM_LOG_DIR"
    return 0
  fi
  case "$(uname -s)" in
    Darwin)  printf '%s\n' "/Library/Logs/nucleus" ;;
    Linux)   printf '%s\n' "/var/log/nucleus" ;;
    *)       printf '%s\n' "/var/log/nucleus" ;;
  esac
}

# log_sanitize — Strip control characters from stdin to stdout.
#
# Removes ANSI escape sequences, carriage returns, and ASCII control
# characters (except tab and newline).
#
# Usage: some_command | log_sanitize
log_sanitize() {
  # Strip ANSI escape sequences and OSC sequences, remove \r, strip
  # control chars except tab (\x09) and newline (\x0A).
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
      -e 's/\x1b\][^\x07\x1b]*\x07//g' \
      -e 's/\x1b[PX^_].*\x1b\\//g' \
      -e 's/\r//g' \
      -e "s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g"
}
