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

# Auto-derived command prefix for output helpers.
# Strips "nucleus-" prefix if present; falls back to basename.
_nuc_prefix="$(basename "$0")"
case "$_nuc_prefix" in
  nucleus-*) _nuc_prefix="${_nuc_prefix#nucleus-}" ;;
esac

# Output helpers — use these instead of raw printf/echo.
# All derive the <cmd>: prefix automatically from the script name.

# say — Print an info message to stdout.
say() { printf '%s\n' "$_nuc_prefix: $*"; }

# error — Print an error message to stderr and return 1.
error() { printf '%s\n' "$_nuc_prefix: error: $*" >&2; return 1; }

# warn — Print a warning message to stderr.
warn() { printf '%s\n' "$_nuc_prefix: warning: $*" >&2; }

# dry_run — Print a dry-run message to stdout.
dry_run() { printf '%s\n' "$_nuc_prefix: [dry-run] $*"; }

# section — Print a section header to stdout.
section() { printf '\n=== [%s] %s ===\n' "$1" "$2"; }

# nuc_done — Print a completion message to stdout.
nuc_done() { printf '%s\n' "$_nuc_prefix: done"; }

# Resolution order: NUCLEUS_REPO_ROOT env var, SCRIPT_DIR+offset auto-discovery, then git rev-parse.
derive_repo_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
    NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$NUCLEUS_REPO_ROOT" && pwd -P)"
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
    if [ -n "${_drr_git_root:-}" ] && [ -f "$_drr_git_root/src/flake.nix" ]; then
      printf '%s\n' "$_drr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "derive_repo_root: cannot determine nucleus repository root — set NUCLEUS_REPO_ROOT or run from within the nucleus repo" >&2
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
  _mnc_base="${1:-experimental-features = nix-command flakes}"
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "$_mnc_base"
  else
    printf '%s' "$_mnc_base"
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
    Darwin)  printf '%s\n' "/Users/Shared/nucleus/logs" ;;
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

# launchctl_target — Build a macOS launchctl service target specifier.
# macOS 25+ requires gui/<uid>/<service> for user domain and
# system/<service> for system domain. Older macOS accepted bare service IDs.
launchctl_target() {
  if [ "$1" = "system" ]; then
    printf 'system/%s' "$2"
  else
    printf 'gui/%s/%s' "$(id -u)" "$2"
  fi
}

# refresh_cfprefsd — Kill cfprefsd (CFPreferences daemon) on macOS.
# Caches all defaults read/write in process memory; kill forces re-read from
# plist on next access.  No-op on non-macOS.
refresh_cfprefsd() {
  case "$(uname -s)" in
    Darwin)
      /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
      ;;
  esac
}

# refresh_pbs — Kill pbs (Pasteboard Server + Services manager) on macOS.
# Caches NSServicesStatus at startup; kill forces re-read of pbs.plist so
# new/changed services appear in menus.  No-op on non-macOS.
refresh_pbs() {
  case "$(uname -s)" in
    Darwin)
      /usr/bin/killall -KILL pbs 2>/dev/null || true
      ;;
  esac
}

# refresh_lsd — Rebuild the Launch Services database on macOS.
# Kills lsd (Launch Services Daemon); on restart it rebuilds from scratch,
# picking up newly registered .app bundles.  No-op on non-macOS.
refresh_lsd() {
  case "$(uname -s)" in
    Darwin)
      /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
      ;;
  esac
}

# refresh_finder — Restart Finder on macOS via killall.
# No-op on non-macOS.
refresh_finder() {
  case "$(uname -s)" in
    Darwin)
      /usr/bin/killall Finder 2>/dev/null || true
      ;;
  esac
}

# refresh_dock — Restart Dock on macOS via killall.
# No-op on non-macOS.
refresh_dock() {
  case "$(uname -s)" in
    Darwin)
      /usr/bin/killall Dock 2>/dev/null || true
      ;;
  esac
}

# refresh_services_menu — Full flush of the Services menu pipeline on macOS.
# Kills cfprefsd, lsd, pbs, waits 1 s, then restarts Finder.
# Call this after deploying or removing .app bundles so the Services menu
# reflects the new state without a logout/reboot.
# No-op on non-macOS.
refresh_services_menu() {
  case "$(uname -s)" in
    Darwin)
      /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
      /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
      /usr/bin/killall -KILL pbs 2>/dev/null || true
      /bin/sleep 1
      /usr/bin/killall Finder 2>/dev/null || true
      ;;
  esac
}

# rotate_log_file — Copy-truncate a single log file if it exceeds MAXSIZE.
# Preserves the inode so open file descriptors (launchd/systemd) stay valid.
# Archives are shifted: .1 (newest) through .$maxfiles (oldest).
# When compress is "true", the .1 archive is gzip-compressed to .1.gz.
rotate_log_file() {
  _rlf_logfile="$1"
  _rlf_maxsize="${2:-10000000}" # bytes
  _rlf_maxfiles="${3:-4}"
  _rlf_compress="${4:-true}"

  [ -f "$_rlf_logfile" ] || return 0

  _rlf_size=$(wc -c < "$_rlf_logfile")
  [ "$_rlf_size" -le "$_rlf_maxsize" ] && return 0

  if [ "$_rlf_maxfiles" -gt 0 ]; then
    # Remove oldest archive
    rm -f "$_rlf_logfile.$_rlf_maxfiles" "$_rlf_logfile.$_rlf_maxfiles.gz"

    # Shift existing archives
    _rlf_i=$((_rlf_maxfiles - 1))
    while [ "$_rlf_i" -ge 1 ]; do
      [ -f "$_rlf_logfile.$_rlf_i" ] && mv "$_rlf_logfile.$_rlf_i" "$_rlf_logfile.$((_rlf_i + 1))"
      [ -f "$_rlf_logfile.$_rlf_i.gz" ] && mv "$_rlf_logfile.$_rlf_i.gz" "$_rlf_logfile.$((_rlf_i + 1)).gz"
      _rlf_i=$((_rlf_i - 1))
    done

    # Copy-truncate: copy to archive, then truncate in-place
    cp "$_rlf_logfile" "$_rlf_logfile.1"
    : > "$_rlf_logfile"

    # Compress the newest archive if requested
    if [ "$_rlf_compress" = "true" ]; then
      gzip -f "$_rlf_logfile.1" 2>/dev/null || true
    fi
  else
    # maxfiles=0: just truncate, keep no archives
    : > "$_rlf_logfile"
  fi
}

# rotate_logs_in_directory — Iterate over all *.log files under DIR and rotate
# each one via rotate_log_file.  Uses POSIX find for portability.
rotate_logs_in_directory() {
  _rld_dir="$1"
  _rld_maxsize="${2:-10000000}" # bytes
  _rld_maxfiles="${3:-4}"
  _rld_compress="${4:-true}"

  [ -d "$_rld_dir" ] || return 0

  find "$_rld_dir" -name '*.log' -type f | while IFS= read -r _rld_logfile; do
    rotate_log_file "$_rld_logfile" "$_rld_maxsize" "$_rld_maxfiles" "$_rld_compress"
  done
}
