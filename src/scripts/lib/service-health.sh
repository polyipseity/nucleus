# shellcheck shell=bash
# Unified per-instance health record for nucleus services, one JSON file per
# instance in <nucleus_user_root>/state/service-stats/.
#
# Two writers: the runner classifies a MOUNT (mounted, provider-refused, attempts
# exhausted), the watchdog the SUPERVISOR (crash-looping, not-loaded). They meet on
# the fields both observe: state, class, remedy, lastSuccess, lastExit. generation,
# restarts and reportedState are watchdog-only, evidence is runner-only. lastExit
# has two writers without interfering because both report the same exit the
# supervisor observed, and Rule 5 dispatches on 78 (EX_CONFIG).
#
# `generation` is the supervisor run token as of the last observation and the single
# input to loop detection. It is null until the first observation, and null is the
# only unobserved sentinel: the token itself may legitimately read zero (systemd's
# NRestarts). `evidence` stays null once a mount reaches running rather than
# disappearing, and svc_health_clear leaves it alone.
#
# Only svc_health_clear removes class/remedy. The apply-time re-arm is
# src/scripts/services/reset-service-health.sh, which removes records outright.

[ -n "${_NUCLEUS_SERVICE_HEALTH_SOURCED-}" ] && return
_NUCLEUS_SERVICE_HEALTH_SOURCED=1

_SVC_HEALTH_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SVC_HEALTH_LIB_DIR/lib.sh"

# Loop policy, read by both the detector and the status formatter so they cannot disagree.
readonly _SVC_HEALTH_LOOP_RESTARTS=10
readonly _SVC_HEALTH_LOOP_CONSECUTIVE=5
readonly _SVC_HEALTH_WARN_RESTARTS=5

svc_health_state_dir() {
  local root="${NUCLEUS_USER_ROOT:-$(derive_nucleus_user_root)}"
  printf '%s/state/service-stats' "$root"
}

svc_health_state_file() {
  local instance="$1"
  printf '%s/%s.json' "$(svc_health_state_dir)" "$instance"
}

# Sentinel for "the OS could not report a boot time", see svc_health_boot_id.
_SVC_HEALTH_BOOT_UNKNOWN='unknown'

# The value is constant within one boot and different after a reboot, and is
# recomputed on every call because a cached value cannot change across a reboot.
#
# Sources, all satisfying that contract: /proc/stat btime, `uptime -s` when /proc is
# unavailable, sysctl kern.boottime, and `who -b`, the only one that works where
# sysctl is denied. `uptime -s` does not exist on macOS. The `who -b` token carries
# no year, so two boots in different years collide; that direction fails closed.
svc_health_os_boot_time() {
  local _v=""
  # check-suppress:suppression_doc: best-effort probe; no output means this source is unavailable
  _v="$(sed -n 's/^btime \([0-9][0-9]*\)$/\1/p' /proc/stat 2>/dev/null | head -n 1)"
  if [ -n "$_v" ]; then
    printf '%s' "$_v"
    return 0
  fi
  # check-suppress:suppression_doc: best-effort probe; no output means this source is unavailable
  _v="$(uptime -s 2>/dev/null)" || _v=''
  if [ -n "$_v" ]; then
    printf '%s' "$_v"
    return 0
  fi
  # check-suppress:suppression_doc: best-effort probe; no output means this source is unavailable
  _v="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')"
  if [ -n "$_v" ]; then
    printf '%s' "$_v"
    return 0
  fi
  # check-suppress:suppression_doc: best-effort probe; no output means this source is unavailable
  _v="$(who -b 2>/dev/null | sed -n 's/.*boot *//p' | tr -s ' ' | sed 's/^ *//; s/ *$//')"
  if [ -n "$_v" ]; then
    printf '%s' "$_v"
    return 0
  fi
  printf ''
}

# WHY recomputed rather than cached in a file: the record's `boot` is compared against this value to decide whether a block still stands, so it MUST change across a reboot and a cached copy cannot.
# WHY an unavailable boot time yields a sentinel rather than empty or a fresh `date +%s`: clearing a block is driven by the stored boot differing from this value, so a fabricated value makes every block read as stale and re-admits the restart storm the block guards. The sentinel means "not evidence of a reboot" and keeps the block; failing closed costs nothing the apply-time re-arm cannot fix.
svc_health_boot_id() {
  local _boot
  _boot="$(svc_health_os_boot_time)"
  if [ -z "$_boot" ]; then
    printf '%s' "$_SVC_HEALTH_BOOT_UNKNOWN"
    return 0
  fi
  printf '%s' "$_boot"
}

svc_health_init() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  if [ -f "$file" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  printf '{"state":"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":"%s","lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}\n' \
    "$(svc_health_boot_id)" >"$tmp"
  mv "$tmp" "$file"
}

svc_health_read() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] && cat "$file"
}

svc_health_get() {
  local instance="$1" field="$2" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || return 0
  jq -r ".$field // empty" "$file" 2>/dev/null
}

# Writes through a tmp file plus mv, so a reader never sees a partial record.
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
    printf '{"state":"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":"%s","lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}\n' \
      "$(svc_health_boot_id)" >"$tmp"
    if ! jq ".$field = $value" "$tmp" >"${tmp}.mv" 2>/dev/null; then
      rm -f "$tmp" "${tmp}.mv"
      return 1
    fi
    mv "${tmp}.mv" "$tmp"
  fi
  mv "$tmp" "$file"
}

svc_health_set_state() {
  svc_health_set "$1" "state" "\"$2\""
}

svc_health_set_blocked() {
  local instance="$1" class="$2" remedy="$3"
  svc_health_init "$instance"
  local file tmp
  file="$(svc_health_state_file "$instance")"
  tmp="${file}.tmp.$$"
  if ! jq -c \
    --arg class "$class" \
    --arg remedy "$remedy" \
    --arg boot "$(svc_health_boot_id)" \
    '.state = "blocked" | .class = $class | .remedy = $remedy | .boot = $boot | .reportedState = null' \
    "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

svc_health_set_running() {
  local instance="$1"
  svc_health_set "$instance" "state" "\"running\""
  svc_health_set "$instance" "class" "null"
  svc_health_set "$instance" "remedy" "null"
}

# Fresh means the record was written during the current boot, so a record from a previous boot stops gating the service. That is how a reboot clears a block.
# WHY the unknown/absent guards: when the OS cannot report a boot time, or the record carries no boot stamp, a mismatch is not evidence of a reboot, so the block is kept.
svc_health_is_blocked() {
  local instance="$1" state boot current
  state="$(svc_health_get "$instance" "state")"
  [ "$state" = "blocked" ] || return 1
  boot="$(svc_health_get "$instance" "boot")"
  current="$(svc_health_boot_id)"
  case "$current" in '' | "$_SVC_HEALTH_BOOT_UNKNOWN") return 0 ;; esac
  case "$boot" in '' | "$_SVC_HEALTH_BOOT_UNKNOWN") return 0 ;; esac
  [ "$boot" = "$current" ]
}

svc_health_is_reported() {
  local instance="$1" expected="$2"
  local current
  current="$(svc_health_get "$instance" "reportedState")"
  [ "$current" = "$expected" ]
}

svc_health_mark_reported() {
  svc_health_set "$1" "reportedState" "\"$2\""
}

# WHY drop .restarts: svc_health_is_looping reads it, so a clear that kept the history would be re-blocked by Rule 3 on the very next tick.
svc_health_clear() {
  local instance="$1" file tmp
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || return 0
  tmp="${file}.tmp.$$"
  if ! jq -c '.state = "stopped" | .class = null | .remedy = null | .reportedState = null | .restarts = []' "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

svc_health_record_restart() {
  local instance="$1" reason="${2:-}"
  svc_health_init "$instance"
  local file now tmp
  file="$(svc_health_state_file "$instance")"
  now=$(date +%s)
  local cutoff=$((now - 3600))
  tmp="${file}.tmp.$$"
  if ! jq -c --argjson now "$now" --argjson cutoff "$cutoff" \
    '.restarts = ([.restarts[]? | select(. > $cutoff)] + [$now])' \
    "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  if [ -n "$reason" ]; then
    notice "service-health: recorded restart for $instance ($reason)"
  fi
}

svc_health_record_success() {
  local instance="$1"
  svc_health_init "$instance"
  local file now tmp
  file="$(svc_health_state_file "$instance")"
  now=$(date +%s)
  tmp="${file}.tmp.$$"
  if ! jq -c --argjson now "$now" '.lastSuccess = $now' "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

svc_health_restart_count() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || {
    echo 0
    return
  }
  local now cutoff count
  now=$(date +%s)
  cutoff=$((now - 3600))
  # WHY: a corrupt record is REPORTED, never read as a healthy zero, which would let the loop detector fail open and print OK for a service that may be in a restart storm.
  if ! count="$(jq -r --argjson cutoff "$cutoff" \
    '[.restarts[]? | select(. > $cutoff)] | length' "$file" 2>/dev/null)"; then
    warn "service-health: unreadable health record for $instance (restart count)"
    printf '0'
    return 0
  fi
  printf '%s' "$count"
}

# WHY lastSuccess is bound to a variable first: inside `[.restarts[]? | select(...)]` the current value is a restart timestamp, a number, so selecting on `.lastSuccess` there indexes a number, jq fails, the fallback reports zero, and only the 10-restarts-per-hour rule can break a loop.
svc_health_consecutive_failures() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || {
    echo 0
    return
  }
  # WHY: same as svc_health_restart_count, a corrupt record is reported rather than counted as zero.
  local count
  if ! count="$(jq -r '(.lastSuccess // 0) as $ls | [.restarts[]? | select(. > $ls)] | length' "$file" 2>/dev/null)"; then
    warn "service-health: unreadable health record for $instance (consecutive failures)"
    printf '0'
    return 0
  fi
  printf '%s' "$count"
}

svc_health_is_looping() {
  local count consecutive
  count="$(svc_health_restart_count "$1")"
  consecutive="$(svc_health_consecutive_failures "$1")"
  count="${count:-0}"
  consecutive="${consecutive:-0}"
  [ "$count" -ge "$_SVC_HEALTH_LOOP_RESTARTS" ] || [ "$consecutive" -ge "$_SVC_HEALTH_LOOP_CONSECUTIVE" ]
}

# "OK", "N/hr" (warning) or "LOOP" (crash-looping), decided by the same predicate the watchdog acts on so the reported status cannot disagree with the enforced policy.
svc_health_status() {
  local count
  count="$(svc_health_restart_count "$1")"
  count="${count:-0}"
  if svc_health_is_looping "$1"; then
    printf 'LOOP'
  elif [ "$count" -ge "$_SVC_HEALTH_WARN_RESTARTS" ]; then
    printf '%d/hr' "$count"
  else
    printf 'OK'
  fi
}

svc_health_set_last_exit() {
  svc_health_set "$1" "lastExit" "$2"
}

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
