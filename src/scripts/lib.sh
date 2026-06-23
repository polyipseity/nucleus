# shellcheck shell=sh
# Source this at the top of nucleus POSIX shell scripts after setting SCRIPT_DIR.
# Provides shared functions (usage_std, derive_repo_root).
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../src/scripts/lib.sh"
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Repository root path. Falls back to auto-detection if unset.

usage_std() {
  _us_name="$1"
  _us_opts="${2:-}"
  shift 2 2>/dev/null || true

  printf 'usage: %s %s\n' "$_us_name" "$_us_opts"
  if [ "$#" -gt 0 ]; then
    printf '  %s\n' "$1"
  fi
}

# Resolution order: NUCLEUS_REPO_ROOT env var, SCRIPT_DIR+offset auto-discovery, then git rev-parse.
derive_repo_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
    printf '%s\n' "$NUCLEUS_REPO_ROOT"
    return 0
  fi
  for _drr_offset in ".." "../.." "../../.."; do
    _drr_candidate="$(CDPATH='' cd -- "${SCRIPT_DIR:?}/${_drr_offset}" && pwd -P 2>/dev/null)" || continue
    if [ -f "$_drr_candidate/src/flake.nix" ]; then
      printf '%s\n' "$_drr_candidate"
      return 0
    fi
  done
  if command -v git >/dev/null 2>&1; then
    _drr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    if [ -n "${_drr_git_root:-}" ] && [ -d "$_drr_git_root" ]; then
      printf '%s\n' "$_drr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "derive_repo_root: cannot determine repository root" >&2
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

# Tries sha256sum, shasum -a 256, then openssl dgst -sha256.
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

# Platform-aware user log directory.
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

# Platform-aware system log directory.
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

# Strip ANSI escapes, \r, and control chars (keep tab, newline).
log_sanitize() {
  # Strip ANSI escape sequences and OSC sequences, remove \r, strip
  # control chars except tab (\x09) and newline (\x0A).
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
      -e 's/\x1b\][^\x07\x1b]*\x07//g' \
      -e 's/\x1b[PX^_].*\x1b\\//g' \
      -e 's/\r//g' \
      -e "s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g"
}
