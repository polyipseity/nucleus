#!/usr/bin/env bash
# logs.sh — Unified log viewer for POSIX hosts (macOS + NixOS).
#
# Displays service logs from the nucleus logging system.
# On macOS, reads from file-based logs under
#   ~/Library/Logs/nucleus/{service}/{stdout,stderr}.log
#   /Library/Logs/nucleus/{service}/{stdout,stderr}.log
# On NixOS, queries journald for systemd services and reads files for
# non-systemd services.
#
# Usage: nucleus logs [service...] [options]
#
# Arguments:
#   service                      Names of services to show logs for.
#
# Options:
#   --lines N, -n N              Last N lines per source (default: 10).
#   --since DURATION             Since a duration (e.g. 1h, 30m, 2d).
#                                  Only supported for journald-backed services.
#   --paths                      Print log file paths instead of tailing.
#   --raw                        Skip sanitization (show raw control chars).
#   --stdout                     Show only stdout (separate-file services only).
#   --stderr                     Show only stderr (separate-file services only).
#   --json                       Machine-readable output (list mode).
#   -h, --help                   Show usage.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[service...] [options]"
  cat <<'EOF'
View service logs from the nucleus logging system.

ARGUMENTS:
  service               Service name(s) to show logs for (default: list all).

OPTIONS:
  --lines N, -n N       Last N lines per source (default: 10).
  --since DURATION      Logs since duration (1h, 30m, 2d; journald only).
  --paths               Print log file paths only.
  --raw                 Skip sanitization (show raw control chars).
  --stdout              Show only stdout (separate-file services only).
  --stderr              Show only stderr (separate-file services only).
  --json                Machine-readable output (list mode).
  -h, --help            Show usage.
EOF
}

# --- Resolve paths and platform ---
REPO_ROOT="$(resolve_nucleus_root)"
SERVICES_JSON="$REPO_ROOT/src/modules/services.json"
HOST="$(resolve_nucleus_host)"

case "$HOST" in
  MacBook) PLATFORM="macos" ;;
  NixOS)   PLATFORM="nixos" ;;
  *)
    printf '%s\n' "logs: unsupported host '$HOST'" >&2
    exit 1
    ;;
esac

# --- Defaults ---
LINES=10
SINCE=""
JSON=false
PATHS=false
RAW=false
STDOUT=false
STDERR=false
HELP=false
declare -a SERVICES=()

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) HELP=true; shift ;;
    -n|--lines) LINES="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    --paths) PATHS=true; shift ;;
    --raw) RAW=true; shift ;;
    --stdout) STDOUT=true; shift ;;
    --stderr) STDERR=true; shift ;;
    --) shift; break ;;
    -*)
      printf '%s\n' "logs: unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *) SERVICES+=("$1"); shift ;;
  esac
done

$HELP && { usage; exit 0; }

# Validate --lines
case "$LINES" in
  ''|*[!0-9]*) printf '%s\n' "logs: --lines must be a number" >&2; exit 1 ;;
esac

require_command jq

# --- Helpers ---

# Get sorted list of services defined for this platform in services.json
get_platform_services() {
  jq -r --arg platform "$PLATFORM" '
    to_entries[]
    | select(.key | startswith("$") | not)
    | select(.value.platforms[$platform] != null)
    | .key
  ' "$SERVICES_JSON" | sort
}

# Get capture mode: platform-specific overrides top-level
get_capture() {
  local svc="$1"
  jq -r --arg svc "$svc" --arg platform "$PLATFORM" '
    (.[$svc].platforms[$platform].logging.capture // .[$svc].logging.capture // "all")
  ' "$SERVICES_JSON"
}

# Get the systemd unit name for a NixOS service
get_unit() {
  local svc="$1"
  jq -r --arg svc "$svc" '
    (.[$svc].platforms.nixos.service // "")
  ' "$SERVICES_JSON"
}

# Print all log file paths for a service (user + system dirs)
service_log_files() {
  local svc="$1"
  local user_dir system_dir

  user_dir="$(nucleus_log_dir)/$svc"
  system_dir="$(nucleus_system_log_dir)/$svc"

  if $STDOUT; then
    [ -f "$user_dir/stdout.log" ] && printf '%s\n' "$user_dir/stdout.log"
    [ -f "$system_dir/stdout.log" ] && printf '%s\n' "$system_dir/stdout.log"
  elif $STDERR; then
    [ -f "$user_dir/stderr.log" ] && printf '%s\n' "$user_dir/stderr.log"
    [ -f "$system_dir/stderr.log" ] && printf '%s\n' "$system_dir/stderr.log"
  else
    # Show all log files
    for d in "$user_dir" "$system_dir"; do
      [ -d "$d" ] && find "$d" -name '*.log' -type f 2>/dev/null || true
    done
  fi
}

# Check if a service has any accessible log output
service_has_logs() {
  local svc="$1"
  local capture
  capture="$(get_capture "$svc")"

  # File-based: check for log files
  if [ "$capture" != "none" ]; then
    [ -n "$(service_log_files "$svc")" ] && return 0
  fi

  # journald (NixOS systemd): check if unit exists and has logs
  if [ "$PLATFORM" = "nixos" ]; then
    local unit
    unit="$(get_unit "$svc")"
    if [ -n "$unit" ] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$unit" -n 1 --quiet --no-pager >/dev/null 2>&1 && return 0
    fi
  fi

  return 1
}

# Parse a human-readable duration into journalctl --since format.
# Simple cases: 1h, 30m, 2d → "1 hour ago", "30 minutes ago", "2 days ago".
parse_since() {
  local val="$1"
  case "$val" in
    *h) printf '%s hour ago\n' "${val%h}" ;;
    *m) printf '%s minutes ago\n' "${val%m}" ;;
    *d) printf '%s days ago\n' "${val%d}" ;;
    *)  printf '%s\n' "$val" ;; # pass-through (ISO 8601, "yesterday", etc.)
  esac
}

# Check if a log file has been modified within the given duration.
# Uses find -mmin/-mtime based on the duration suffix.
file_modified_since() {
  local file="$1"
  local duration="$2"
  local minutes=0

  case "$duration" in
    *h) minutes=$((${duration%h} * 60)) ;;
    *m) minutes="${duration%m}" ;;
    *d) minutes=$((${duration%d} * 1440)) ;;
    *)  return 0 ;; # unknown format, show file
  esac

  [ -n "$(find "$file" -mmin "-$minutes" -type f 2>/dev/null)" ]
}

# --- Display implementations ---

# Show file-based logs for a service
show_file_logs() {
  local svc="$1"
  local files
  files="$(service_log_files "$svc")"

  if [ -z "$files" ]; then
    printf 'logs: %s — no log files found\n' "$svc" >&2
    return
  fi

  local sanitize_cmd="log_sanitize"
  $RAW && sanitize_cmd="cat"

  # When following with no specific --lines, use tail -F for continuous follow.
  # When --lines is given explicitly (even if default 10), show that many lines.
  if [ -n "$SINCE" ] && [ "$PLATFORM" = "nixos" ]; then
    # --since with file logs on NixOS: use find to filter files by mtime
    local filtered=""
    while IFS= read -r f; do
      if file_modified_since "$f" "$SINCE"; then
        filtered="$filtered$f "
      fi
    done <<< "$files"
    if [ -z "$filtered" ]; then
      # Show nothing recent; still show a brief summary
      printf 'logs: %s — no activity within %s (file-based)\n' "$svc" "$SINCE" >&2
      return
    fi
    # shellcheck disable=SC2086
    tail -n "$LINES" $filtered | $sanitize_cmd
  else
    # shellcheck disable=SC2086
    tail -F -n "$LINES" $files | $sanitize_cmd
  fi
}

# Show journald logs for a service (NixOS only)
show_journald_logs() {
  local svc="$1"
  local unit
  unit="$(get_unit "$svc")"

  if [ -z "$unit" ]; then
    printf 'logs: %s — no systemd unit found\n' "$svc" >&2
    return
  fi

  local since_arg=()
  if [ -n "$SINCE" ]; then
    since_arg=(--since "$(parse_since "$SINCE")")
  fi

  local sanitize_cmd="log_sanitize"
  $RAW && sanitize_cmd="cat"

  journalctl -u "$unit" -n "$LINES" -f --no-pager -o cat "${since_arg[@]}" | $sanitize_cmd
}

# Print log paths for one or all services
show_paths() {
  if [ "${#SERVICES[@]}" -gt 0 ]; then
    for svc in "${SERVICES[@]}"; do
      service_log_files "$svc"
    done
  else
    while IFS= read -r svc; do
      local files
      files="$(service_log_files "$svc")"
      [ -n "$files" ] && printf '%s\n' "$files"
    done <<< "$(get_platform_services)"
  fi
}

# List services with log availability
list_services() {
  if $JSON; then
    printf '[\n'
    local first=true
    while IFS= read -r svc; do
      $first || printf ',\n'
      first=false
      printf '  "%s"' "$svc"
    done <<< "$(get_platform_services)"
    printf '\n]\n'
  else
    printf 'Available services:\n\n'
    while IFS= read -r svc; do
      local capture
      capture="$(get_capture "$svc")"
      local has_logs=true
      service_has_logs "$svc" || has_logs=false

      if $has_logs; then
        printf '  %-25s capture=%-7s\n' "$svc" "$capture"
      else
        printf '  %-25s capture=%-7s (no logs yet)\n' "$svc" "$capture"
      fi
    done <<< "$(get_platform_services)"
  fi
}

# --- Main ---

if $PATHS; then
  show_paths
  exit 0
fi

if [ "${#SERVICES[@]}" -eq 0 ]; then
  list_services
  exit 0
fi

# Show logs for requested services
for svc in "${SERVICES[@]}"; do
  # Validate service exists
  if ! get_platform_services | grep -qx "$svc"; then
    printf 'logs: unknown service "%s" for platform %s\n' "$svc" "$PLATFORM" >&2
    exit 1
  fi

  capture="$(get_capture "$svc")"

  # Dispatch based on platform and capture mode
  case "$PLATFORM" in
    macos)
      if [ "$capture" = "none" ]; then
        printf 'logs: %s — capture disabled, no file logs\n' "$svc" >&2
        continue
      fi
      show_file_logs "$svc"
      ;;
    nixos)
      unit="$(get_unit "$svc")"
      if [ -n "$unit" ] && command -v journalctl >/dev/null 2>&1; then
        show_journald_logs "$svc"
      elif [ "$capture" != "none" ]; then
        show_file_logs "$svc"
      else
        printf 'logs: %s — capture disabled and no systemd unit\n' "$svc" >&2
        continue
      fi
      ;;
  esac
done
