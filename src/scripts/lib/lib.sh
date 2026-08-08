# shellcheck shell=sh
# Source this at the top of nucleus POSIX shell scripts after setting SCRIPT_DIR.
# Provides shared functions (usage_std, derive_repo_root).
#
# Guard against re-sourcing — step files source this independently and
# re-sourcing would redundantly re-export PARALLEL_JOBS and redefine functions.
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] && return
_NUCLEUS_LIB_SOURCED=1
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../src/scripts/lib.sh"
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Repository root path. Falls back to auto-detection if unset.
#   PARALLEL_JOBS      Worker count for parallel operations. Auto-detected from CPU count if unset.

# Auto-scale parallelism to available CPU cores.
# Override via PARALLEL_JOBS environment variable.
: "${PARALLEL_JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2)}"
export PARALLEL_JOBS

usage_std() {
  _us_name="$1"
  _us_opts="${2:-}"
  shift 2 2>/dev/null

  printf 'usage: %s %s\n' "$_us_name" "$_us_opts"
  if [ "$#" -gt 0 ]; then
    printf '  %s\n' "$1"
  fi
}

# Auto-derived command prefix for output helpers.
# Strips "nucleus-" prefix if present; falls back to basename.
_nuc_prefix="$(basename "$0")"
# Strip .sh extension for cleaner prefix (e.g., "svc:" instead of "svc.sh:")
_nuc_prefix="${_nuc_prefix%.sh}"
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

# Resolution order: NUCLEUS_REPO_ROOT env var, /etc/nucleus/repo-root, SCRIPT_DIR+offset, then git rev-parse.
derive_repo_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
    NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$NUCLEUS_REPO_ROOT" && pwd -P)"
    printf '%s\n' "$NUCLEUS_REPO_ROOT"
    return 0
  fi
  _drr_system_file="${NUCLEUS_REPO_ROOT_SYSTEM_FILE:-/etc/nucleus/repo-root}"
  if [ -f "$_drr_system_file" ]; then
    # WHY: sudo/su reset the environment; /etc/nucleus/repo-root (materialized at
    # apply time) gives all-process repo-root availability on POSIX hosts.
    IFS= read -r _drr_system_root < "$_drr_system_file" \
      || _drr_system_root="" # check-suppress:suppression_doc: unreadable system file treated as absent.
    case "$_drr_system_root" in
      /*) ;;
      *) _drr_system_root="" ;; # reject empty/relative system file paths
    esac
    if [ -n "$_drr_system_root" ] && [ -f "$_drr_system_root/src/flake.nix" ]; then
      printf '%s\n' "$_drr_system_root"
      return 0
    fi
  fi
  # Resolve SCRIPT_DIR to the physical path before traversal so symlink chains
  # (e.g. /Users -> /System/Volumes/Data/Users, iCloud Drive) do not interfere
  # with directory climbing.
  _drr_base="$(CDPATH='' cd -P -- "${SCRIPT_DIR:?}" 2>/dev/null && pwd)" || true # check-suppress:suppression_doc: SCRIPT_DIR may not exist or be unset; fall through to git fallback.
  if [ -n "$_drr_base" ]; then
    for _drr_offset in ".." "../.." "../../.."; do
      _drr_candidate="$(CDPATH='' cd -P -- "${_drr_base}/${_drr_offset}" 2>/dev/null && pwd)" || continue
      if [ -f "$_drr_candidate/src/flake.nix" ]; then
        printf '%s\n' "$_drr_candidate"
        return 0
      fi
      if [ -f "$_drr_candidate/.nucleus-repo-root" ]; then
        # WHY: store-installed apps bundle scripts/ + src/scripts/ but not
        # src/flake.nix; the marker (baked from NUCLEUS_REPO_ROOT at build time)
        # points at the canonical checkout.
        IFS= read -r _drr_marker_root < "$_drr_candidate/.nucleus-repo-root" \
          || _drr_marker_root="" # check-suppress:suppression_doc: unreadable marker treated as absent.
        case "$_drr_marker_root" in
          /*) ;;
          *) _drr_marker_root="" ;; # reject empty/relative marker paths
        esac
        if [ -n "$_drr_marker_root" ] && [ -f "$_drr_marker_root/src/flake.nix" ]; then
          printf '%s\n' "$_drr_marker_root"
          return 0
        fi
      fi
    done
  fi
  if command -v git >/dev/null 2>&1; then
    _drr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true # check-suppress:suppression_doc: git rev-parse may fail outside a git repo; fallback continues with error message.
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

# Pre-flight availability check with a hint to run nucleus-apply.
# Unlike require_command, this is meant for the pre-flight block and
# gives a user-friendly message linking to the provisioning system.
# Does NOT attempt nix profile install — see package-installation-scope.
ensure_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    printf '%s\n' "  Run nucleus-apply to install it, or use nix run .#check to run via flake." >&2
    exit 1
  fi
}

# run_command_with_timeout SECONDS COMMAND...
#   Run COMMAND in the background; return its exit code, or 124 on timeout.
run_command_with_timeout() {
  _rcwt_timeout="$1"
  shift
  (
    "$@" &
    _rcwt_pid=$!
    _rcwt_elapsed=0
    while kill -0 "$_rcwt_pid" 2>/dev/null; do
      if [ "$_rcwt_elapsed" -ge "$_rcwt_timeout" ]; then
        # check-suppress:suppression_doc: timed-out process may already be dead; kill failure must not abort exit 124 path.
        kill "$_rcwt_pid" 2>/dev/null || true
        # check-suppress:suppression_doc: wait after kill on timed-out process may fail harmlessly.
        wait "$_rcwt_pid" 2>/dev/null || true
        exit 124
      fi
      sleep 1
      _rcwt_elapsed=$((_rcwt_elapsed + 1))
    done
    wait "$_rcwt_pid"
  )
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

# Path to host-platform-registry.json in the nucleus repo.
nucleus_host_platform_registry_path() {
  _nhprp_repo="${NUCLEUS_REPO_ROOT:-}"
  if [ -z "$_nhprp_repo" ]; then
    _nhprp_repo="$(derive_repo_root)" || return 1
  fi
  printf '%s\n' "$_nhprp_repo/src/modules/host-platform-registry.json"
}

# Read platform key for a host from host-platform-registry.json.
nucleus_platform_for_host() {
  _npfh_host="${1:-}"
  if [ -z "$_npfh_host" ]; then
    _npfh_host="$(resolve_nucleus_host)"
  fi
  require_command jq
  _npfh_json="$(nucleus_host_platform_registry_path)" || return 1
  _npfh_platform="$(jq -r --arg h "$_npfh_host" '.hosts[$h].platform // empty' "$_npfh_json")"
  if [ -z "$_npfh_platform" ]; then
    printf '%s\n' "nucleus_platform_for_host: unknown host '$_npfh_host'" >&2
    return 1
  fi
  printf '%s\n' "$_npfh_platform"
}

# Test whether a platform flag is set for a host (via registry platforms section).
nucleus_flag_for_host() {
  _nffh_host="${1:-}"
  _nffh_flag="${2:-}"
  if [ -z "$_nffh_host" ] || [ -z "$_nffh_flag" ]; then
    printf '%s\n' "nucleus_flag_for_host: host and flag are required" >&2
    return 1
  fi
  require_command jq
  _nffh_json="$(nucleus_host_platform_registry_path)" || return 1
  _nffh_platform="$(nucleus_platform_for_host "$_nffh_host")" || return 1
  jq -e --arg p "$_nffh_platform" --arg f "$_nffh_flag" '.platforms[$p].flags[$f] == true' "$_nffh_json" >/dev/null
}

# Path to services.json in the nucleus repo.
nucleus_services_json_path() {
  _nsjp_repo="${NUCLEUS_REPO_ROOT:-}"
  if [ -z "$_nsjp_repo" ]; then
    _nsjp_repo="$(derive_repo_root)" || return 1
  fi
  printf '%s\n' "$_nsjp_repo/src/modules/services.json"
}

# Expand ~ in POSIX log path templates.
nucleus_expand_log_path() {
  _nelp_path="$1"
  case "$_nelp_path" in
    '~')
      printf '%s\n' "${HOME}"
      ;;
    '~'/*)
      _nelp_suffix="${_nelp_path#~/}"
      printf '%s\n' "${HOME}/${_nelp_suffix}"
      ;;
    *)
      printf '%s\n' "$_nelp_path"
      ;;
  esac
}

# Read logDir or systemLogDir from services.json $logging for the current host.
nucleus_log_path_from_json() {
  _nlpfj_field="$1"

  if [ "$_nlpfj_field" = logDir ] && [ -n "${NUCLEUS_LOG_DIR:-}" ]; then
    printf '%s\n' "$NUCLEUS_LOG_DIR"
    return 0
  fi
  if [ "$_nlpfj_field" = systemLogDir ] && [ -n "${NUCLEUS_SYSTEM_LOG_DIR:-}" ]; then
    printf '%s\n' "$NUCLEUS_SYSTEM_LOG_DIR"
    return 0
  fi

  require_command jq
  _nlpfj_json="$(nucleus_services_json_path)" || return 1
  _nlpfj_host="$(resolve_nucleus_host)"
  _nlpfj_template="$(jq -r --arg h "$_nlpfj_host" --arg f "$_nlpfj_field" '.["$logging"][$h][$f] // empty' "$_nlpfj_json")"
  [ -n "$_nlpfj_template" ] || return 1

  if [ "$_nlpfj_field" = logDir ]; then
    nucleus_expand_log_path "$_nlpfj_template"
  else
    printf '%s\n' "$_nlpfj_template"
  fi
}

# Host-aware user log directory.
nucleus_log_dir() {
  nucleus_log_path_from_json logDir
}

# Host-aware system log directory.
nucleus_system_log_dir() {
  nucleus_log_path_from_json systemLogDir
}

# Caddy state directory sibling to the system log root (/Users/Shared/nucleus/caddy).
nucleus_caddy_state_dir() {
  _ncsd_sys="$(nucleus_system_log_dir)" || return 1
  printf '%s\n' "$(dirname -- "$_ncsd_sys")/caddy"
}

# sccache_cache_dir — Resolve the local sccache disk cache directory.
# Honors SCCACHE_DIR when set; otherwise uses platform defaults from upstream
# sccache Local.md.
sccache_cache_dir() {
  if [ -n "${SCCACHE_DIR:-}" ]; then
    printf '%s\n' "$SCCACHE_DIR"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "${HOME}/Library/Caches/Mozilla.sccache" ;;
    Linux)  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/sccache" ;;
    *)      printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/sccache" ;;
  esac
}

# clear_sccache_cache — Stop the sccache server and delete local cache files.
# sccache has no --clear flag; disk cache must be removed directly.
clear_sccache_cache() {
  if ! command -v sccache >/dev/null 2>&1; then
    warn "sccache unavailable; skipping sccache cache gc"
    return 0
  fi

  say "sccache: clearing cache"
  # check-suppress:suppression_doc: sccache server may not be running; stop is best-effort before cache removal.
  sccache --stop-server 2>/dev/null || true

  _csc_cache_dir="$(sccache_cache_dir)"
  if [ -d "$_csc_cache_dir" ]; then
    rm -rf -- "${_csc_cache_dir:?}"/*
  fi
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

  _rlf_logdir=$(dirname -- "$_rlf_logfile")
  if [ ! -w "$_rlf_logfile" ] || [ ! -w "$_rlf_logdir" ]; then
    warn "skipping log rotation for unwritable '$_rlf_logfile'"
    return 0
  fi

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
    if ! cp "$_rlf_logfile" "$_rlf_logfile.1"; then
      warn "failed to rotate '$_rlf_logfile': archive copy failed"
      return 0
    fi
    if ! : > "$_rlf_logfile"; then
      warn "failed to rotate '$_rlf_logfile': truncate failed"
      return 0
    fi

    # Compress the newest archive if requested
    if [ "$_rlf_compress" = "true" ]; then
      # check-suppress:suppression_doc: archived log may not exist yet on first rotation; gzip -f exits 1 for missing files.
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

# Parse duration strings like 7d or 24h into whole-day counts for find -mtime.
parse_expiry_days() {
  _ped_exp="${1:-7d}"
  case "$_ped_exp" in
    *d) printf '%s\n' "${_ped_exp%d}" ;;
    *h) printf '%s\n' $(( (${_ped_exp%h} + 23) / 24 )) ;;
    *)  printf '%s\n' 7 ;;
  esac
}

# Delete rotated archives and dated application logs older than EXPIRY (default 7d).
expire_logs_in_directory() {
  _eld_dir="$1"
  _eld_expiry="${2:-7d}"

  [ -d "$_eld_dir" ] || return 0
  _eld_days="$(parse_expiry_days "$_eld_expiry")"
  [ "$_eld_days" -gt 0 ] || return 0

  find "$_eld_dir" -type f \
    \( -name '*.log.[0-9]*' -o -name '*.log.gz' -o -name '*.log.[0-9]*.gz' -o -name 'log_*.log' \) \
    -mtime +"${_eld_days}" -delete
}

# kill_processes_on_port — Kill all processes listening on PORT.
# Uses lsof -ti :PORT to find PIDs. Sends SIGTERM, waits 2s, then SIGKILL
# survivors. No-op if port is free.
# Returns 0 if port freed, 1 if still occupied.
kill_processes_on_port() {
  _klp_port="$1"

  require_command lsof

  # check-suppress:suppression_doc: no process may be listening on this port; empty result is expected.
  _klp_pids="$(lsof -ti :"$_klp_port" 2>/dev/null)" || true
  [ -z "$_klp_pids" ] && return 0

  # SIGTERM
  # check-suppress:suppression_doc: process may have already exited before SIGTERM arrives.
  printf '%s\n' "$_klp_pids" | xargs kill -TERM 2>/dev/null || true

  # Wait up to 2s (4 x 0.5s)
  _klp_i=0
  while [ "$_klp_i" -lt 4 ]; do
    # check-suppress:suppression_doc: no process may be listening on this port; empty result is expected.
    _klp_pids="$(lsof -ti :"$_klp_port" 2>/dev/null)" || true
    [ -z "$_klp_pids" ] && return 0
    sleep 0.5
    _klp_i=$((_klp_i + 1))
  done

  # SIGKILL survivors
  # check-suppress:suppression_doc: process may have already exited before SIGKILL arrives.
  printf '%s\n' "$_klp_pids" | xargs kill -KILL 2>/dev/null || true
  sleep 0.5

  # check-suppress:suppression_doc: no process may be listening on this port; empty result is expected.
  _klp_pids="$(lsof -ti :"$_klp_port" 2>/dev/null)" || true
  [ -z "$_klp_pids" ] && return 0
  return 1
}

# wait_for_port — Poll for PORT to enter LISTEN state.
# Polls lsof -i :PORT every 0.5s up to TIMEOUT seconds (default 5). HOST
# param is accepted for API consistency but unused on macOS/Linux.
# Returns 0 when port appears in LISTEN state, 1 on timeout.
wait_for_port() {
  _wfp_port="$1"
  _wfp_host="${2:-}"       # unused on macOS/Linux
  _wfp_timeout="${3:-5}"

  require_command lsof

  _wfp_max_checks=$((_wfp_timeout * 2))
  _wfp_i=0
  while [ "$_wfp_i" -lt "$_wfp_max_checks" ]; do
    if lsof -i :"$_wfp_port" 2>/dev/null | grep -q LISTEN; then
      return 0
    fi
    sleep 0.5
    _wfp_i=$((_wfp_i + 1))
  done
  return 1
}

# extract_ports — Parse network endpoints from a service entry JSON.
# Input: a JSON string (platform-filtered service entry with optional network
# block). Output: one "host port" line per named endpoint, newline-separated.
# Returns empty if no network key.
extract_ports() {
  _ep_json="$1"

  require_command jq

  printf '%s\n' "$_ep_json" | jq -r '
    .network // empty | to_entries[] | "\(.value.host // "0.0.0.0") \(.value.port)"
  ' 2>/dev/null || true # check-suppress:suppression_doc: service entry may not have a network block; jq returns empty, not an error.
}
