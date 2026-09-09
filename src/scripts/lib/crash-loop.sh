# shellcheck shell=bash
# Crash-loop detection for nucleus services.
# Tracks restart timestamps in per-service state files under
# <nucleus_user_root>/state/service-stats/.
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "$SCRIPT_DIR/../lib/crash-loop.sh"
#
#   crash_loop_record "betterdisplay-heartbeat" "not-running"
#   crash_loop_success "betterdisplay-heartbeat"
#   if crash_loop_is_looping "betterdisplay-heartbeat"; then
#     warn "service is crash-looping"
#   fi

[ -n "${_NUCLEUS_CRASH_LOOP_SOURCED-}" ] && return
_NUCLEUS_CRASH_LOOP_SOURCED=1

# Source lib.sh for derive_nucleus_user_root if not already loaded.
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "${SCRIPT_DIR}/lib.sh"

# crash_loop_state_dir — returns the state directory path.
crash_loop_state_dir() {
  local root
  root="$(derive_nucleus_user_root)"
  printf '%s/state/service-stats' "$root"
}

# crash_loop_state_file — returns the state file path for a service.
crash_loop_state_file() {
  local service="$1"
  printf '%s/%s.json' "$(crash_loop_state_dir)" "$service"
}

# crash_loop_read_state — reads state file, outputs "restarts_csv lastSuccess".
# If file missing, outputs " none".
crash_loop_read_state() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf ' none'
    return
  fi
  local restarts last_success
  restarts=$(jq -r '.restarts // [] | join(",")' "$file" 2>/dev/null || printf '')
  last_success=$(jq -r '.lastSuccess // 0' "$file" 2>/dev/null || printf '0')
  if [ -z "$restarts" ]; then
    printf ' %s' "$last_success"
  else
    printf ' %s %s' "$restarts" "$last_success"
  fi
}

# crash_loop_write_state — writes state file with pruned restarts (last hour).
crash_loop_write_state() {
  local file="$1" restarts_csv="$2" last_success="$3"
  local now cutoff
  now=$(date +%s)
  cutoff=$((now - 3600))

  # Prune restarts older than 1 hour, write atomically.
  local tmp="${file}.tmp.$$"
  if [ -z "$restarts_csv" ] || [ "$restarts_csv" = "0" ]; then
    printf '{"restarts":[],"lastSuccess":%s}\n' "$last_success" >"$tmp"
  else
    # Filter timestamps > cutoff, build JSON array.
    printf '%s' "$restarts_csv" | awk -v cutoff="$cutoff" -F',' '
    {
      n = split($1, a, ",")
      printf "["
      first = 1
      for (i = 1; i <= n; i++) {
        if (a[i] + 0 > cutoff) {
          if (!first) printf ","
          printf "%s", a[i]
          first = 0
        }
      }
      printf "]"
    }' >"$tmp"
    # Wrap with lastSuccess.
    local arr
    arr=$(cat "$tmp")
    printf '{"restarts":%s,"lastSuccess":%s}\n' "$arr" "$last_success" >"$tmp"
  fi
  mv "$tmp" "$file"
}

# crash_loop_record — record a restart event for a service.
# Appends current timestamp to state file. Prunes entries older than 1 hour.
crash_loop_record() {
  local service="$1" reason="${2:-}"
  local file
  file="$(crash_loop_state_file "$service")"
  mkdir -p "$(dirname "$file")"

  local now restarts last_success
  now=$(date +%s)

  if [ -f "$file" ]; then
    restarts=$(jq -r '.restarts // [] | join(",")' "$file" 2>/dev/null || printf '')
    last_success=$(jq -r '.lastSuccess // 0' "$file" 2>/dev/null || printf '0')
  else
    restarts=""
    last_success="0"
  fi

  # Append new timestamp.
  if [ -z "$restarts" ]; then
    restarts="$now"
  else
    restarts="${restarts},${now}"
  fi

  crash_loop_write_state "$file" "$restarts" "$last_success"

  # Log if reason provided.
  if [ -n "$reason" ]; then
    notice "crash-loop: recorded restart for %s (%s)" "$service" "$reason"
  fi
}

# crash_loop_success — record a successful start for a service.
# Updates lastSuccess timestamp in state file.
crash_loop_success() {
  local service="$1"
  local file
  file="$(crash_loop_state_file "$service")"
  mkdir -p "$(dirname "$file")"

  local now restarts last_success
  now=$(date +%s)

  if [ -f "$file" ]; then
    restarts=$(jq -r '.restarts // [] | join(",")' "$file" 2>/dev/null || printf '')
    last_success=$(jq -r '.lastSuccess // 0' "$file" 2>/dev/null || printf '0')
  else
    restarts=""
    last_success="0"
  fi

  crash_loop_write_state "$file" "$restarts" "$now"
}

# crash_loop_restart_count — count restarts in the last hour from state file.
crash_loop_restart_count() {
  local service="$1"
  local file
  file="$(crash_loop_state_file "$service")"

  if [ ! -f "$file" ]; then
    echo 0
    return
  fi

  local now cutoff restarts count
  now=$(date +%s)
  cutoff=$((now - 3600))
  restarts=$(jq -r '.restarts // [] | join(",")' "$file" 2>/dev/null || printf '')

  if [ -z "$restarts" ]; then
    echo 0
    return
  fi

  count=$(printf '%s' "$restarts" | awk -v cutoff="$cutoff" -F',' '{
    n = split($1, a, ",")
    c = 0
    for (i = 1; i <= n; i++) {
      if (a[i] + 0 > cutoff) c++
    }
    print c
  }')
  echo "$count"
}

# crash_loop_consecutive_failures — count consecutive restarts with no success.
# Reads restarts array and lastSuccess from state file. If the N most recent
# restarts all have timestamps > lastSuccess, the service has N consecutive failures.
crash_loop_consecutive_failures() {
  local service="$1"
  local file
  file="$(crash_loop_state_file "$service")"

  if [ ! -f "$file" ]; then
    echo 0
    return
  fi

  local last_success restarts
  last_success=$(jq -r '.lastSuccess // 0' "$file" 2>/dev/null || printf '0')
  restarts=$(jq -r '.restarts // [] | join(",")' "$file" 2>/dev/null || printf '')

  if [ -z "$restarts" ]; then
    echo 0
    return
  fi

  # Count restarts that are more recent than lastSuccess (from newest to oldest).
  printf '%s' "$restarts" | awk -v ls="$last_success" -F',' '{
    n = split($1, a, ",")
    c = 0
    for (i = n; i >= 1; i--) {
      if (a[i] + 0 > ls) c++
      else break
    }
    print c
  }'
}

# crash_loop_is_looping — check if a service is in a crash loop.
# Returns 0 (true) if looping, 1 (false) if not.
# Looping criteria: ≥10 restarts/hour OR ≥5 consecutive failures.
crash_loop_is_looping() {
  local service="$1"
  local count consecutive
  count=$(crash_loop_restart_count "$service")
  consecutive=$(crash_loop_consecutive_failures "$service")

  if [ "$count" -ge 10 ] || [ "$consecutive" -ge 5 ]; then
    return 0
  fi
  return 1
}

# crash_loop_status — print status string for a service.
# Outputs: "OK", "⚠ N/hr" (warning, 5-9 restarts), or "🔄 LOOP" (crash-looping).
crash_loop_status() {
  local service="$1"
  local count consecutive
  count=$(crash_loop_restart_count "$service")
  consecutive=$(crash_loop_consecutive_failures "$service")

  if [ "$count" -ge 10 ] || [ "$consecutive" -ge 5 ]; then
    printf '🔄 LOOP'
  elif [ "$count" -ge 5 ]; then
    printf '⚠ %d/hr' "$count"
  else
    printf 'OK'
  fi
}
