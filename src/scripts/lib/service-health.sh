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
#     "generation": null,
#     "lastExit": 0 }
#
# Writers, per field. There is no single writer for the whole record, and the
# two jobs are deliberately different: the runner classifies a MOUNT (mounted,
# provider-refused, attempts exhausted) while the watchdog classifies the
# SUPERVISOR (crash-looping, not-loaded). They necessarily meet on the fields
# both can observe.
#
#   state, class, remedy    runner (rclone-mount.sh, mount-backend-*: running,
#                           provider-refusal, mount-failed) AND the watchdog
#                           (crash-loop, not-loaded)
#   lastSuccess             runner (a successful mount) AND the watchdog (a tick
#                           that observed an unchanged supervisor token)
#   lastExit                runner (the mount watch's status) AND the watchdog
#                           (the supervisor's own last exit)
#   generation              watchdog only — the supervisor run token
#   restarts, reportedState watchdog only
#   boot                    svc_health_init and svc_health_set_blocked
#   attempts                svc_health_init only — no production caller advances it
#
# Only svc_health_clear (the repair path, once a mount is confirmed back) removes
# class/remedy; nothing else clears a block.  The apply-time re-arm is
# src/scripts/services/reset-service-health.sh — it removes the records outright,
# which is why no clear-all counterpart lives in this library.
#
# WHY lastExit has two writers without interfering: Rule 5 dispatches on
#   lastExit == 78 (EX_CONFIG), and both writers report the same underlying
#   value — the runner takes the mount watch's status, the watchdog the
#   supervisor's record of that same process — so whichever ran last, the
#   comparison sees the exit the supervisor actually observed.
#
# `generation` is the supervisor's run token as of the last observation, and it
# is the single input to loop detection: the watchdog records a restart whenever
# the token changes between ticks.  It is null until the first observation, and
# null is the ONLY unobserved sentinel — the token itself may legitimately read
# zero (systemd's NRestarts), so zero cannot double as "never observed" without
# swallowing each service's first restart.
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

# Loop policy — the single definition of every loop threshold. The detector and
# the status formatter both read these, so the two can never disagree.
readonly _SVC_HEALTH_LOOP_RESTARTS=10
readonly _SVC_HEALTH_LOOP_CONSECUTIVE=5
readonly _SVC_HEALTH_WARN_RESTARTS=5

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

# Sentinel for "the OS could not report a boot time" — see svc_health_boot_id.
_SVC_HEALTH_BOOT_UNKNOWN='unknown'

# svc_health_os_boot_time — the operating system's current boot time.
#
# Contract: the value is IDENTICAL throughout one boot and DIFFERENT after a
# reboot. It is recomputed on every call and deliberately NOT cached, because a
# cached value cannot change across a reboot — which is the entire point of it.
# The output is an opaque non-empty token; empty means the OS could not report a
# boot time at all.
#
# The sources are per host, because the hosts expose different facilities, but
# all of them satisfy the same contract:
#   Linux  /proc/stat "btime" — an exact boot epoch, the most precise source
#   Linux  `uptime -s`        — the same value as text, when /proc is unavailable
#   macOS  kern.boottime      — "{ sec = <epoch>, usec = 0 }"; needs sysctl
#   macOS  `who -b`           — the utmpx boot record, and the ONLY source that
#                               works where sysctl is denied (sandboxed contexts)
# WHY `uptime -s` is not the universal source: it does not exist on macOS (it
# exits 1 with "illegal option -- s"), which is why the macOS branches exist.
# WHY the `who -b` token carries no year: it renders the boot time without one,
# so two boots at the same month/day/time in different years produce the same
# token. That direction is fail-closed (a block persists), which is the safe
# side — see svc_health_boot_id.
svc_health_os_boot_time() {
  local _v=""
  # check-suppress:suppression_doc: best-effort probe; no output means this source is unavailable
  _v="$(sed -n 's/^btime \([0-9][0-9]*\)$/\1/p' /proc/stat 2>/dev/null | head -n 1)"
  if [ -n "$_v" ]; then
    printf '%s' "$_v"
    return 0
  fi
  # `uptime -s` does not exist on macOS, so this branch failing is expected.
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

# svc_health_boot_id — the boot identity stamped into a record.
#
# WHY this is recomputed rather than cached in a file (it previously read a
# sticky `<state dir>/.boot-id`): the record's `boot` is compared against this
# value to decide whether a block is still in force, so the value MUST change
# when the OS reboots. A cached copy cannot, which left the documented "a reboot
# clears a block" contract unreachable — on macOS the cached value was
# additionally only a creation timestamp, because the `uptime -s` it was built
# from always failed there and fell through to `date +%s`.
#
# WHY an unavailable boot time yields a sentinel rather than an empty value or a
# fresh `date +%s`: clearing a block is driven by the stored boot DIFFERING from
# this value, so fabricating a value when the OS cannot be asked would make every
# block read as stale — silently voiding the protection that exists to stop a
# restart storm, and doing so with no operator signal. The sentinel instead means
# "this is not evidence of a reboot", and svc_health_is_blocked keeps the block.
# Failing closed costs a blocked instance nothing that the apply-time re-arm
# (nucleus-apply, which removes the records) cannot fix; failing open re-admits
# the restart storm, which is the harm the block exists to prevent.
svc_health_boot_id() {
  local _boot
  _boot="$(svc_health_os_boot_time)"
  if [ -z "$_boot" ]; then
    printf '%s' "$_SVC_HEALTH_BOOT_UNKNOWN"
    return 0
  fi
  printf '%s' "$_boot"
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
  printf '{"state":"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":"%s","lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}\n' \
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
# Args: $1 — instance; $2 — field name (e.g. state, class, remedy, generation, lastExit).
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

# svc_health_set_running — update state, clear class/remedy.
svc_health_set_running() {
  local instance="$1"
  svc_health_set "$instance" "state" "\"running\""
  svc_health_set "$instance" "class" "null"
  svc_health_set "$instance" "remedy" "null"
}

# svc_health_is_blocked — return 0 if the instance has a fresh blocked record.
# Fresh means the record was written during the CURRENT boot, so a record from a
# previous boot stops gating the service — that is how a reboot clears a block
# (the other way being the apply-time re-arm).
# WHY the unknown/absent guards: when the OS cannot report a boot time, or the
# record carries no boot stamp at all, a mismatch is NOT evidence of a reboot,
# so the block is KEPT (fail closed). See svc_health_boot_id for why failing
# closed is the safe direction here.
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
  svc_health_set "$1" "reportedState" "\"$2\""
}

# svc_health_clear — re-arm the instance: drop class, remedy, and reportedState,
# return state to "stopped", and drop the restart history, so that neither a
# blocked state NOR a loop history survives the re-arm.
# WHY: svc_health_is_looping reads .restarts (via svc_health_restart_count and
#   svc_health_consecutive_failures), so a clear that kept the history would be
#   re-blocked by the watchdog's Rule 3 on the very next tick and would stay
#   blocked until the old timestamps aged out.  Dropping .restarts is what makes
#   this a re-arm rather than a status reset.
# Called by repair once a mount is confirmed back.
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

# svc_health_record_restart — append a restart timestamp, prune entries >1 hour.
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

# svc_health_record_success — update lastSuccess to now.
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

# svc_health_restart_count — count restarts in the last hour.
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
  # WHY: a corrupt record must be REPORTED, never silently read as a healthy
  #   zero.  The previous `|| echo 0` made the loop detector fail open and print
  #   OK for a service that may be in a restart storm.
  if ! count="$(jq -r --argjson cutoff "$cutoff" \
    '[.restarts[]? | select(. > $cutoff)] | length' "$file" 2>/dev/null)"; then
    warn "service-health: unreadable health record for $instance (restart count)"
    printf '0'
    return 0
  fi
  printf '%s' "$count"
}

# svc_health_consecutive_failures — count restarts newer than lastSuccess.
# WHY: lastSuccess is bound to a variable first.  Inside `[.restarts[]? |
#   select(...)]` the current value is a restart timestamp — a number — so
#   selecting on `.lastSuccess` there indexes a number, jq fails, and the
#   fallback below reports zero.  The fast consecutive-failure rule then never
#   fires and only the 10-restarts-per-hour rule can break a loop.
svc_health_consecutive_failures() {
  local instance="$1" file
  file="$(svc_health_state_file "$instance")"
  [ -f "$file" ] || {
    echo 0
    return
  }
  # WHY: same as svc_health_restart_count — a corrupt record is reported rather
  #   than silently counted as zero failures.
  local count
  if ! count="$(jq -r '(.lastSuccess // 0) as $ls | [.restarts[]? | select(. > $ls)] | length' "$file" 2>/dev/null)"; then
    warn "service-health: unreadable health record for $instance (consecutive failures)"
    printf '0'
    return 0
  fi
  printf '%s' "$count"
}

# svc_health_is_looping — return 0 if the service is in a crash loop.
# Looping criteria live in the _SVC_HEALTH_LOOP_* constants above.
svc_health_is_looping() {
  local count consecutive
  count="$(svc_health_restart_count "$1")"
  consecutive="$(svc_health_consecutive_failures "$1")"
  count="${count:-0}"
  consecutive="${consecutive:-0}"
  [ "$count" -ge "$_SVC_HEALTH_LOOP_RESTARTS" ] || [ "$consecutive" -ge "$_SVC_HEALTH_LOOP_CONSECUTIVE" ]
}

# svc_health_status — print status string for a service.
# "OK", "N/hr" (warning, 5-9 restarts), or "LOOP" (crash-looping).
# WHY: LOOP is decided by svc_health_is_looping, the same predicate the watchdog
# acts on, so the reported status can never disagree with the enforced policy.
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
