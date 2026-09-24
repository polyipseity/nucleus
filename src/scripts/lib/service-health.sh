# shellcheck shell=bash
# Unified per-instance health record for nucleus services.
# Replaces the separate crash-loop state and blocked-marker files with a
# single JSON file per instance in <nucleus_user_root>/state/service-stats/.
#
# Record schema:
#   { "state": "running|stopped|blocked",
#     "class": null | "<class-token>",
#     "remedy": null | "<remedy-text>",
#     "attempts": 0,
#     "reportedState": null,
#     "boot": "<boot-id>",
#     "lastSuccess": 0,
#     "restarts": [],
#     "runs": 0,
#     "lastExit": 0 }
#
# The runner writes state, class, remedy, attempts, lastSuccess.
# The watchdog writes restarts, reportedState, runs, lastExit.
# Only clear (apply) removes class/remedy.
#
# Usage:
#   . "$SCRIPT_DIR/../lib/service-health.sh"
#
#   svc_health_set_state "cloud-mount-iCloud" "blocked"
#   svc_health_set_blocked "cloud-mount-iCloud" "provider-refusal" "re-enable macFUSE"
#   if svc_health_is_blocked "cloud-mount-iCloud"; then ... fi

[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] && return
_NUCLEUS_SERVICE_HEALTH_SOURCED=1

# Source lib.sh for derive_nucleus_user_root if not already loaded.
_SVC_HEALTH_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SVC_HEALTH_LIB_DIR/lib.sh"

# svc_health_state_dir — returns the state directory path.
svc_health_state_dir() {
  local root="${NUCLEUS_USER_ROOT:-$(derive_nucleus_user_root)}"
  printf '%s/state/service-stats' "$root"
}

# svc_health_state_file — returns the state file path for a service instance.
svc_health_state_file() {
  local instance="$1"
  printf '%s/%s.json' "$(svc_health_state_dir)" "$instance"
}

# svc_health_boot_id — returns a boot identifier for freshness tracking.
# WHY: svc_boot_id in svc-instances.sh provides this; we reuse the same
# mechanism so a reboot clears stale records.
svc_health_boot_id() {
  local _svc_health_boot_id_file
  _svc_health_boot_id_file="$(svc_health_state_dir)/.boot-id"
  if [ -f "$_svc_health_boot_id_file" ]; then
    cat "$_svc_health_boot_id_file" 2>/dev/null || printf ''
    return
  fi
  local _svc_health_boot_id_val
  _svc_health_boot_id_val="$(uptime -s 2>/dev/null || date +%s)"
  mkdir -p "$(svc_health_state_dir)"
  printf '%s' "$_svc_health_boot_id_val" >"$_svc_health_boot_id_file"
  printf '%s' "$_svc_health_boot_id_val"
}

# svc_health_init — ensure the state file exists with defaults.
svc_health_init() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  if [ -f "$file" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  printf '{"state":"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":"%s","lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}\n' \
    "$(svc_health_boot_id)" >"$tmp"
  mv "$tmp" "$file"
}

# svc_health_read — read the full JSON record. Prints nothing if missing.
svc_health_read() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] && cat "$file"
}

# svc_health_get — read a single field from the record.
# Args: $1 — instance; $2 — field name (e.g. state, class, remedy, runs, lastExit).
svc_health_get() {
  local instance="$1" field="$2" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || return 0
  jq -r ".$field // empty" "$file" 2>/dev/null
}

# svc_health_set — write a field to the record. Atomic via tmp+mv.
# Args: $1 — instance; $2 — field; $3 — value (JSON-encoded string, number, null).
svc_health_set() {
  local instance="$1" field="$2" value="$3" file tmp
  file="$(svc_health_state_file "$instance")"
  mkdir -p "$(dirname "$file")"
  tmp="${file}.tmp.$$"
  if [ -f "$file" ]; then
    if ! jq ".$field = $value" "$file" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  else
    printf '{"state":"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":"%s","lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}\n' \
      "$(svc_health_boot_id)" >"$tmp"
    if ! jq ".$field = $value" "$tmp" >"${tmp}.mv" 2>/dev/null; then
      rm -f "$tmp" "${tmp}.mv"
      return 1
    fi
    mv "${tmp}.mv" "$tmp"
  fi
  mv "$tmp" "$file"
}

# svc_health_set_state — update the state field.
svc_health_set_state() {
  svc_health_set "$1" "state" "\"$2\""
}

# svc_health_set_blocked — set state to blocked with class and remedy.
svc_health_set_blocked() {
  local instance="$1" class="$2" remedy="$3"
  svc_health_init "$instance"
  local file tmp
  file="$(svc_health_state_file "$instance")"
  tmp="${file}.tmp.$$"
  jq -c \
    --arg class "$class" \
    --arg remedy "$remedy" \
    --arg boot "$(svc_health_boot_id)" \
    '.state = "blocked" | .class = $class | .remedy = $remedy | .boot = $boot | .reportedState = null' \
    "$file" >"$tmp" 2>/dev/null
  mv "$tmp" "$file"
}

# svc_health_set_running — update state, clear class/remedy, update runs.
svc_health_set_running() {
  local instance="$1"
  svc_health_set "$instance" "state" "\"running\""
  svc_health_set "$instance" "class" "null"
  svc_health_set "$instance" "remedy" "null"
}

# svc_health_is_blocked — return 0 if the instance has a fresh blocked record.
# Fresh means the boot matches the current boot.
svc_health_is_blocked() {
  local instance="$1" state boot
  state="$(svc_health_get "$instance" "state")"
  [ "$state" = "blocked" ] || return 1
  boot="$(svc_health_get "$instance" "boot")"
  [ "$boot" = "$(svc_health_boot_id)" ]
}

# svc_health_is_reported — return 0 if the current state has been reported.
# Args: $1 — instance key; $2 — expected reportedState string.
svc_health_is_reported() {
  local instance="$1" expected="$2"
  local current
  current="$(svc_health_get "$instance" "reportedState")"
  [ "$current" = "$expected" ]
}

# svc_health_mark_reported — mark the current state as reported.
# Args: $1 — instance key; $2 — reportedState string.
svc_health_mark_reported() {
  svc_health_set "$1" "reportedState" "$2"
}

# svc_health_clear — remove class, remedy, and reportedState (re-arm the instance).
# Called by apply-time clear-stale-blocks or equivalent.
svc_health_clear() {
  local instance="$1" file tmp
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || return 0
  tmp="${file}.tmp.$$"
  jq -c '.class = null | .remedy = null | .reportedState = null' "$file" >"$tmp" 2>/dev/null
  mv "$tmp" "$file"
}

# svc_health_clear_all — clear all instances (apply-time re-arm).
svc_health_clear_all() {
  local dir
  dir="$(svc_health_state_dir)"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    svc_health_clear "$(basename "$f" .json)"
  done
}

# svc_health_record_restart — append a restart timestamp, prune entries >1 hour.
svc_health_record_restart() {
  local instance="$1" reason="${2:-}"
  svc_health_init "$instance"
  local file now tmp
  file="$(svc_health_state_file "$instance")"
  now=$(date +%s)
  local cutoff=$((now - 3600))
  tmp="${file}.tmp.$$"
  jq -c --argjson now "$now" --argjson cutoff "$cutoff" \
    '.restarts = ([.restarts[]? | select(. > $cutoff)] + [$now])' \
    "$file" >"$tmp" 2>/dev/null
  mv "$tmp" "$file"
  if [ -n "$reason" ]; then
    notice "service-health: recorded restart for $instance ($reason)"
  fi
}

# svc_health_record_success — update lastSuccess to now.
svc_health_record_success() {
  local instance="$1"
  svc_health_init "$instance"
  local file now tmp
  file="$(svc_health_state_file "$instance")"
  now=$(date +%s)
  tmp="${file}.tmp.$$"
  jq -c --argjson now "$now" '.lastSuccess = $now' "$file" >"$tmp" 2>/dev/null
  mv "$tmp" "$file"
}

# svc_health_restart_count — count restarts in the last hour.
svc_health_restart_count() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || {
    echo 0
    return
  }
  local now cutoff
  now=$(date +%s)
  cutoff=$((now - 3600))
  jq -r --argjson cutoff "$cutoff" \
    '[.restarts[]? | select(. > $cutoff)] | length' "$file" 2>/dev/null || echo 0
}

# svc_health_consecutive_failures — count restarts newer than lastSuccess.
svc_health_consecutive_failures() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || {
    echo 0
    return
  }
  jq -r '[.restarts[]? | select(. > (.lastSuccess // 0))] | length' "$file" 2>/dev/null || echo 0
}

# svc_health_is_looping — return 0 if the service is in a crash loop.
# Looping criteria: >=10 restarts/hour OR >=5 consecutive failures.
svc_health_is_looping() {
  local count consecutive
  count="$(svc_health_restart_count "$1")"
  consecutive="$(svc_health_consecutive_failures "$1")"
  count="${count:-0}"
  consecutive="${consecutive:-0}"
  if [ "$count" -ge 10 ] || [ "$consecutive" -ge 5 ]; then
    return 0
  fi
  return 1
}

# svc_health_status — print status string for a service.
# "OK", "N/hr" (warning, 5-9 restarts), or "LOOP" (crash-looping).
svc_health_status() {
  local count consecutive
  count="$(svc_health_restart_count "$1")"
  consecutive="$(svc_health_consecutive_failures "$1")"
  if [ "$count" -ge 10 ] || [ "$consecutive" -ge 5 ]; then
    printf 'LOOP'
  elif [ "$count" -ge 5 ]; then
    printf '%d/hr' "$count"
  else
    printf 'OK'
  fi
}

# svc_health_increment_runs — atomically increment the runs counter.
svc_health_increment_runs() {
  local instance="$1" file tmp
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || return 0
  tmp="${file}.tmp.$$"
  jq -c '.runs += 1' "$file" >"$tmp" 2>/dev/null
  mv "$tmp" "$file"
}

# svc_health_set_last_exit — update lastExit.
svc_health_set_last_exit() {
  svc_health_set "$1" "lastExit" "$2"
}

# svc_health_render_status — produce a JSON snippet suitable for svc.sh status.
# Combines the blocked note and crash-loop status in one object.
svc_health_render_status() {
  local instance="$1"
  svc_health_init "$instance" 2>/dev/null
  local state class remedy
  state="$(svc_health_get "$instance" "state" 2>/dev/null || printf 'stopped')"
  class="$(svc_health_get "$instance" "class" 2>/dev/null)"
  remedy="$(svc_health_get "$instance" "remedy" 2>/dev/null)"
  printf '{"blocked":%s,"class":%s,"remedy":%s,"status":"%s"}' \
    "$([ "$state" = "blocked" ] && printf 'true' || printf 'false')" \
    "$([ -n "$class" ] && printf '"%s"' "$class" || printf 'null')" \
    "$([ -n "$remedy" ] && printf '"%s"' "$remedy" || printf 'null')" \
    "$(svc_health_status "$instance")"
}
