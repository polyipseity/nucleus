# shellcheck shell=sh
# Source at the top of nucleus POSIX shell scripts after setting SCRIPT_DIR.
# Re-sourcing is redundant: step files source this independently, and a second
# pass re-exports PARALLEL_JOBS and redefines the functions.
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] && return
_NUCLEUS_LIB_SOURCED=1

: "${PARALLEL_JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2)}"
export PARALLEL_JOBS

# Mirrors nucleusUserRootFor in src/modules/lib/nucleus-roots.nix. All
# user-scoped data lives here, never under ~/.config/nucleus (legacy
# migration source only).
derive_nucleus_user_root() {
  case "$(uname -s)" in
  Darwin) printf '%s\n' "$HOME/Library/Application Support/nucleus" ;;
  *) printf '%s\n' "$HOME/.local/share/nucleus" ;;
  esac
}

: "${NUCLEUS_USER_ROOT:=$(derive_nucleus_user_root)}"
export NUCLEUS_USER_ROOT

# Derived from the host SSH key by src/scripts/secrets/derive-host-age-key.sh.
# Shares the services.json system root with the log dir, so one edit moves both.
nucleus_machine_age_key_path() {
  _nmakp_root="$(dirname -- "$(nucleus_system_log_dir)")" || return 1
  printf '%s\n' "$_nmakp_root/sops/age/machine.txt"
}

usage_std() {
  _us_name="$1"
  _us_opts="${2:-}"
  shift 2 2>/dev/null

  printf 'usage: %s %s\n' "$_us_name" "$_us_opts"
  if [ "$#" -gt 0 ]; then
    printf '  %s\n' "$1"
  fi
}

# WHY: only set if unset, tests export a correct prefix before subshells source
# this file, and unconditionally overwriting it breaks notice output.
: "${_nuc_prefix:=$(basename "$0")}"
_nuc_prefix="${_nuc_prefix%.sh}"
case "$_nuc_prefix" in
nucleus-*) _nuc_prefix="${_nuc_prefix#nucleus-}" ;;
esac

# Per-stream color flags _nuc_color_1/_2 and escape variables _nuc_c1_*/_nuc_c2_*,
# empty when disabled. Rules: .agents/instructions/output-handling.instructions.md
_nuc_color_init() {
  [ -n "${_nuc_color_initialized-}" ] && return 0
  _nuc_color_initialized=1

  if [ -n "${NO_COLOR-}" ]; then
    _nuc_color_1=0
    _nuc_color_2=0
  elif [ -n "${CLICOLOR_FORCE-}" ] || { [ -n "${FORCE_COLOR-}" ] && [ "$FORCE_COLOR" != "0" ]; }; then
    _nuc_color_1=1
    _nuc_color_2=1
  else
    _nuc_color_1=0
    _nuc_color_2=0
    case "${TERM-}" in
    dumb) ;;
    *)
      [ -t 1 ] && _nuc_color_1=1
      [ -t 2 ] && _nuc_color_2=1
      ;;
    esac
  fi

  _nuc_esc="$(printf '\033')"
  if [ "$_nuc_color_1" -eq 1 ]; then
    _nuc_c1_bold="${_nuc_esc}[1m"
    _nuc_c1_red="${_nuc_esc}[31m"
    _nuc_c1_green="${_nuc_esc}[32m"
    _nuc_c1_yellow="${_nuc_esc}[33m"
    _nuc_c1_magenta="${_nuc_esc}[35m"
    _nuc_c1_cyan="${_nuc_esc}[36m"
    _nuc_c1_blue="${_nuc_esc}[34m"
    _nuc_c1_underline="${_nuc_esc}[4m"
    _nuc_c1_ulcyan="${_nuc_esc}[4;36m"
    _nuc_c1_dim="${_nuc_esc}[2m"
    _nuc_c1_reset="${_nuc_esc}[0m"
  else
    _nuc_c1_bold=""
    _nuc_c1_red=""
    _nuc_c1_green=""
    _nuc_c1_yellow=""
    _nuc_c1_magenta=""
    _nuc_c1_cyan=""
    _nuc_c1_blue=""
    _nuc_c1_underline=""
    _nuc_c1_ulcyan=""
    _nuc_c1_dim=""
    _nuc_c1_reset=""
  fi
  if [ "$_nuc_color_2" -eq 1 ]; then
    _nuc_c2_bold="${_nuc_esc}[1m"
    _nuc_c2_red="${_nuc_esc}[31m"
    _nuc_c2_green="${_nuc_esc}[32m"
    _nuc_c2_yellow="${_nuc_esc}[33m"
    _nuc_c2_magenta="${_nuc_esc}[35m"
    _nuc_c2_cyan="${_nuc_esc}[36m"
    _nuc_c2_blue="${_nuc_esc}[34m"
    _nuc_c2_underline="${_nuc_esc}[4m"
    _nuc_c2_ulcyan="${_nuc_esc}[4;36m"
    _nuc_c2_dim="${_nuc_esc}[2m"
    _nuc_c2_reset="${_nuc_esc}[0m"
  else
    _nuc_c2_bold=""
    _nuc_c2_red=""
    _nuc_c2_green=""
    _nuc_c2_yellow=""
    _nuc_c2_magenta=""
    _nuc_c2_cyan=""
    _nuc_c2_blue=""
    _nuc_c2_underline=""
    _nuc_c2_ulcyan=""
    _nuc_c2_dim=""
    _nuc_c2_reset=""
  fi
}
_nuc_color_init

# Output helpers. F1 grammar and colour rules:
# .agents/instructions/output-handling.instructions.md

# _nuc_semantic_color <ulcyan> <blue> <reset> colors a message read from stdin.
# WHY: markup goes only through the color variables, which are empty when the
# stream is color-disabled, so plain output stays byte-identical. Never use
# markup delimiters such as backticks, they would run command substitution
# inside a double-quoted printf call site.
_nuc_semantic_color() {
  _nsc_ulcyan="$1"
  _nsc_blue="$2"
  _nsc_reset="$3"
  [ -n "$_nsc_ulcyan" ] || {
    cat
    return 0
  }
  # Quoted spans first, then URLs, so a URL inside quotes still reads as a URL.
  sed -e "s|'\([^']*\)'|${_nsc_blue}'\\1'${_nsc_reset}|g" \
    -e "s|https\{0,1\}://[^[:space:]'\"]*|${_nsc_ulcyan}&${_nsc_reset}|g"
}

say() {
  _say_label="$_nuc_prefix"
  if [ "${1-}" = "-l" ]; then
    _say_label="$2"
    shift 2
  fi
  _say_msg="$(printf '%s\n' "$*" | _nuc_semantic_color "$_nuc_c1_ulcyan" "$_nuc_c1_blue" "$_nuc_c1_reset")"
  printf '%s\n' "${_nuc_c1_bold}${_say_label}${_nuc_c1_reset}: $_say_msg"
}

error() {
  _err_label="$_nuc_prefix"
  if [ "${1-}" = "-l" ]; then
    _err_label="$2"
    shift 2
  fi
  _err_msg="$(printf '%s\n' "$*" | _nuc_semantic_color "$_nuc_c2_ulcyan" "$_nuc_c2_blue" "$_nuc_c2_reset")"
  printf '%s\n' "${_nuc_c2_bold}${_err_label}${_nuc_c2_reset}: ${_nuc_c2_bold}${_nuc_c2_red}error${_nuc_c2_reset}: $_err_msg" >&2
  return 1
}

warn() {
  _warn_label="$_nuc_prefix"
  if [ "${1-}" = "-l" ]; then
    _warn_label="$2"
    shift 2
  fi
  _warn_msg="$(printf '%s\n' "$*" | _nuc_semantic_color "$_nuc_c2_ulcyan" "$_nuc_c2_blue" "$_nuc_c2_reset")"
  printf '%s\n' "${_nuc_c2_bold}${_warn_label}${_nuc_c2_reset}: ${_nuc_c2_bold}${_nuc_c2_yellow}warning${_nuc_c2_reset}: $_warn_msg" >&2
}

dry_run() {
  _dry_label="$_nuc_prefix"
  if [ "${1-}" = "-l" ]; then
    _dry_label="$2"
    shift 2
  fi
  _dry_msg="$(printf '%s\n' "$*" | _nuc_semantic_color "$_nuc_c1_ulcyan" "$_nuc_c1_blue" "$_nuc_c1_reset")"
  printf '%s\n' "${_nuc_c1_bold}${_dry_label}${_nuc_c1_reset}: ${_nuc_c1_bold}${_nuc_c1_magenta}[dry-run]${_nuc_c1_reset} $_dry_msg"
}

notice() {
  _notice_label="$_nuc_prefix"
  if [ "${1-}" = "-l" ]; then
    _notice_label="$2"
    shift 2
  fi
  _notice_msg="$(printf '%s\n' "$*" | _nuc_semantic_color "$_nuc_c1_ulcyan" "$_nuc_c1_blue" "$_nuc_c1_reset")"
  printf '%s\n' "${_nuc_c1_bold}${_notice_label}${_nuc_c1_reset}: ${_nuc_c1_bold}${_nuc_c1_blue}[notice]${_nuc_c1_reset} $_notice_msg"
}

section() { printf '\n%s=== [%s] %s ===%s\n' "${_nuc_c1_bold}${_nuc_c1_cyan}" "$1" "$2" "${_nuc_c1_reset}"; }

nuc_done() {
  _done_label="$_nuc_prefix"
  if [ "${1-}" = "-l" ]; then
    _done_label="$2"
    shift 2
  fi
  printf '%s\n' "${_nuc_c1_bold}${_done_label}${_nuc_c1_reset}: ${_nuc_c1_bold}${_nuc_c1_green}done${_nuc_c1_reset}"
}

die() {
  error "$@"
  exit 1
}

# NUCLEUS_REPO_ROOT, then <SYSTEM root>/repo-root, SCRIPT_DIR walk, then git.
derive_repo_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
    case "$NUCLEUS_REPO_ROOT" in
    /nix/store/*)
      warn "NUCLEUS_REPO_ROOT points to Nix store path ($NUCLEUS_REPO_ROOT); ignoring — use system repo-root file instead"
      ;;
    *)
      NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$NUCLEUS_REPO_ROOT" && pwd -P)"
      printf '%s\n' "$NUCLEUS_REPO_ROOT"
      return 0
      ;;
    esac
  fi
  case "$(uname -s)" in
  Darwin) _drr_default_system_file="/Library/Application Support/nucleus/repo-root" ;;
  *) _drr_default_system_file="/var/lib/nucleus/repo-root" ;;
  esac
  _drr_system_file="${NUCLEUS_REPO_ROOT_SYSTEM_FILE:-$_drr_default_system_file}"
  if [ -f "$_drr_system_file" ]; then
    # WHY: sudo/su reset the environment, and <SYSTEM root>/repo-root is
    # materialized at apply time, so it gives all-process availability.
    IFS= read -r _drr_system_root <"$_drr_system_file" ||
      _drr_system_root="" # check-suppress:suppression_doc: unreadable system file treated as absent.
    case "$_drr_system_root" in
    /nix/store/*)
      # WHY: Nix evaluation can only ever yield a store snapshot; accepting it
      # silently would deploy symlinks into a read-only tree.
      warn "system repo-root file points to Nix store path ($_drr_system_root); ignoring — run nucleus-apply to re-materialize the live path"
      _drr_system_root=""
      ;;
    /*) ;;
    *) _drr_system_root="" ;; # reject empty/relative system file paths
    esac
    if [ -n "$_drr_system_root" ] && [ -f "$_drr_system_root/src/flake.nix" ]; then
      printf '%s\n' "$_drr_system_root"
      return 0
    fi
  fi
  # WHY: physical path first, or a symlink chain such as /Users or iCloud Drive
  # breaks the climb.
  _drr_base="$(CDPATH='' cd -P -- "${SCRIPT_DIR:?}" 2>/dev/null && pwd)" || true # check-suppress:suppression_doc: SCRIPT_DIR may not exist or be unset; fall through to git fallback.
  if [ -n "$_drr_base" ]; then
    for _drr_offset in ".." "../.." "../../.."; do
      _drr_candidate="$(CDPATH='' cd -P -- "${_drr_base}/${_drr_offset}" 2>/dev/null && pwd)" || continue
      if [ -f "$_drr_candidate/src/flake.nix" ]; then
        printf '%s\n' "$_drr_candidate"
        return 0
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

resolve_nucleus_host() {
  if [ -n "${NUCLEUS_HOST:-}" ]; then
    printf '%s\n' "$NUCLEUS_HOST"
    return 0
  fi
  case "$(uname -s)" in
  Darwin) printf '%s\n' "MacBook" ;;
  Linux) printf '%s\n' "NixOS" ;;
  *) printf '%s\n' "Unknown" ;;
  esac
}

# Args: declared path (may hold a __INSTANCE__ placeholder), instance id. The
# placeholder takes the instance with the basename's literal prefix and suffix
# around the token removed, so "local.cloud-mount.__INSTANCE__.plist" with
# instance "local.cloud-mount.iCloud" yields "iCloud". A path without the
# placeholder returns verbatim. A leading ~/ expands to $HOME.
supervisor_resolve_unit_path() {
  _srup_declared="$1" _srup_instance="$2"
  case "$_srup_declared" in
  *__INSTANCE__*)
    _srup_base="${_srup_declared##*/}"
    _srup_litpre="${_srup_base%%__INSTANCE__*}"
    _srup_litpost="${_srup_base#*__INSTANCE__}"
    _srup_value="$_srup_instance"
    if [ -n "$_srup_litpost" ]; then
      case "$_srup_value" in *"$_srup_litpost") _srup_value="${_srup_value%"$_srup_litpost"}" ;; esac
    fi
    if [ -n "$_srup_litpre" ]; then
      case "$_srup_value" in "$_srup_litpre"*) _srup_value="${_srup_value#"$_srup_litpre"}" ;; esac
    fi
    # WHY: POSIX sh has no ${var/pat/rep}, so split at the first placeholder and
    # rejoin, matching bash first-match substitution.
    _srup_head="${_srup_declared%%__INSTANCE__*}"
    _srup_tail="${_srup_declared#*__INSTANCE__}"
    _srup_declared="${_srup_head}${_srup_value}${_srup_tail}"
    ;;
  esac
  case "$_srup_declared" in
  \~/*) _srup_declared="$HOME${_srup_declared#\~}" ;;
  esac
  printf '%s' "$_srup_declared"
}

merge_nix_config() {
  # WHY: min-free = 0 disables Nix automatic GC for scripted pipelines. On APFS
  # the whole container sets free space, so a full Data volume makes every nix
  # command trigger auto-GC and delete flake-input source trees mid-pipeline.
  # Store cleanup is explicit instead (nixStoreGc, gc-weekly, post-apply run_gc),
  # and NIX_CONFIG lines override min-free/max-free in nix.custom.conf.
  _mnc_base="${1:-experimental-features = nix-command flakes}"
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s\nmin-free = 0' "$NIX_CONFIG" "$_mnc_base"
  else
    printf '%s\nmin-free = 0' "$_mnc_base"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 is required but was not found in PATH"
  fi
}

# Pre-flight variant of require_command with a nucleus-apply hint. Does not
# install anything, see package-installation-scope.instructions.md.
ensure_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "$1 is required but was not found in PATH"
    printf '%s\n' "  Run nucleus-apply to install it, or use nix run .#check to run via flake." >&2
    exit 1
  fi
}

# run_command_with_timeout SECONDS COMMAND... exits 124 on timeout.
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

nucleus_host_platform_registry_path() {
  _nhprp_repo="$(derive_repo_root)" || return 1
  printf '%s\n' "$_nhprp_repo/src/modules/host-platform-registry.json"
}

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

nucleus_services_json_path() {
  _nsjp_repo="$(derive_repo_root)" || return 1
  printf '%s\n' "$_nsjp_repo/src/modules/services.json"
}

nucleus_expand_log_path() {
  _nelp_path="$1"
  case "$_nelp_path" in
  '~')
    printf '%s\n' "${HOME}"
    ;;
  '~'/*)
    _nelp_suffix="${_nelp_path#\~/}"
    printf '%s\n' "${HOME}/${_nelp_suffix}"
    ;;
  *)
    printf '%s\n' "$_nelp_path"
    ;;
  esac
}

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

nucleus_log_dir() {
  nucleus_log_path_from_json logDir
}

nucleus_system_log_dir() {
  nucleus_log_path_from_json systemLogDir
}

nucleus_caddy_state_dir() {
  _ncsd_sys="$(nucleus_system_log_dir)" || return 1
  printf '%s\n' "$(dirname -- "$_ncsd_sys")/caddy"
}

# SCCACHE_DIR when set, otherwise the defaults in upstream sccache Local.md.
sccache_cache_dir() {
  if [ -n "${SCCACHE_DIR:-}" ]; then
    printf '%s\n' "$SCCACHE_DIR"
    return 0
  fi
  case "$(uname -s)" in
  Darwin) printf '%s\n' "${HOME}/Library/Caches/Mozilla.sccache" ;;
  Linux) printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/sccache" ;;
  *) printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/sccache" ;;
  esac
}

# WHY: sccache has no --clear flag, so the disk cache is removed directly.
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

# Strips ANSI and OSC sequences, \r, and control chars, keeping tab and newline.
log_sanitize() {
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    -e 's/\x1b\][^\x07\x1b]*\x07//g' \
    -e 's/\x1b[PX^_].*\x1b\\//g' \
    -e 's/\r//g' |
    tr -d '\000-\010\013\014\016-\037'
}

# Copy-truncate keeps the inode, so open launchd/systemd descriptors stay valid.
# Archives shift .1 (newest) through .$maxfiles, and .1.gz when compress is true.
rotate_log_file() {
  _rlf_logfile="$1"
  _rlf_maxsize="${2:-10000000}" # bytes
  _rlf_maxfiles="${3:-4}"
  _rlf_compress="${4:-true}"

  [ -f "$_rlf_logfile" ] || return 0

  _rlf_size=$(wc -c <"$_rlf_logfile")
  [ "$_rlf_size" -le "$_rlf_maxsize" ] && return 0

  _rlf_logdir=$(dirname -- "$_rlf_logfile")
  if [ ! -w "$_rlf_logfile" ] || [ ! -w "$_rlf_logdir" ]; then
    error "log rotation requires write access to '$_rlf_logfile' and '$_rlf_logdir'; run as root or with sudo"
    return 1
  fi

  if [ "$_rlf_maxfiles" -gt 0 ]; then
    rm -f "$_rlf_logfile.$_rlf_maxfiles" "$_rlf_logfile.$_rlf_maxfiles.gz"

    _rlf_i=$((_rlf_maxfiles - 1))
    while [ "$_rlf_i" -ge 1 ]; do
      [ -f "$_rlf_logfile.$_rlf_i" ] && mv "$_rlf_logfile.$_rlf_i" "$_rlf_logfile.$((_rlf_i + 1))"
      [ -f "$_rlf_logfile.$_rlf_i.gz" ] && mv "$_rlf_logfile.$_rlf_i.gz" "$_rlf_logfile.$((_rlf_i + 1)).gz"
      _rlf_i=$((_rlf_i - 1))
    done

    if ! cp "$_rlf_logfile" "$_rlf_logfile.1"; then
      warn "failed to rotate '$_rlf_logfile': archive copy failed"
      return 0
    fi
    if ! : >"$_rlf_logfile"; then
      warn "failed to rotate '$_rlf_logfile': truncate failed"
      return 0
    fi

    if [ "$_rlf_compress" = "true" ]; then
      # check-suppress:suppression_doc: archived log may not exist yet on first rotation; gzip -f exits 1 for missing files.
      gzip -f "$_rlf_logfile.1" 2>/dev/null || true
    fi
  else
    : >"$_rlf_logfile"
  fi
}

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

parse_expiry_days() {
  _ped_exp="${1:-7d}"
  case "$_ped_exp" in
  *d) printf '%s\n' "${_ped_exp%d}" ;;
  *h) printf '%s\n' $(((${_ped_exp%h} + 23) / 24)) ;;
  *) printf '%s\n' 7 ;;
  esac
}

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

kill_processes_on_port() {
  _klp_port="$1"

  require_command lsof

  # check-suppress:suppression_doc: no process may be listening on this port; empty result is expected.
  _klp_pids="$(lsof -ti :"$_klp_port" 2>/dev/null)" || true
  [ -z "$_klp_pids" ] && return 0

  # check-suppress:suppression_doc: process may have already exited before SIGTERM arrives.
  printf '%s\n' "$_klp_pids" | xargs kill -TERM 2>/dev/null || true

  _klp_i=0
  while [ "$_klp_i" -lt 4 ]; do
    # check-suppress:suppression_doc: no process may be listening on this port; empty result is expected.
    _klp_pids="$(lsof -ti :"$_klp_port" 2>/dev/null)" || true
    [ -z "$_klp_pids" ] && return 0
    sleep 0.5
    _klp_i=$((_klp_i + 1))
  done

  # check-suppress:suppression_doc: process may have already exited before SIGKILL arrives.
  printf '%s\n' "$_klp_pids" | xargs kill -KILL 2>/dev/null || true
  sleep 0.5

  # check-suppress:suppression_doc: no process may be listening on this port; empty result is expected.
  _klp_pids="$(lsof -ti :"$_klp_port" 2>/dev/null)" || true
  [ -z "$_klp_pids" ] && return 0
  return 1
}

# Polls lsof -i :PORT every 0.5s up to TIMEOUT seconds, default 5. HOST is
# accepted for API consistency and unused.
wait_for_port() {
  _wfp_port="$1"
  _wfp_host="${2:-}" # unused on macOS/Linux
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

# Platform-filtered service entry JSON in, one "host port" line per endpoint out,
# empty when the entry has no network block.
extract_ports() {
  _ep_json="$1"

  require_command jq

  printf '%s\n' "$_ep_json" | jq -r '
    .network // empty | to_entries[] | "\(.value.host // "0.0.0.0") \(.value.port)"
  ' 2>/dev/null || true # check-suppress:suppression_doc: service entry may not have a network block; jq returns empty, not an error.
}
