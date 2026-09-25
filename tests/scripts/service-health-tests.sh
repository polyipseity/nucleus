#!/usr/bin/env bash
# Tests for src/scripts/lib/service-health.sh — the single per-instance health
# record: its canonical schema, the loop policy it enforces, and the re-arm
# semantics every caller depends on.  Assertions describe that contract, not
# whatever state this host happens to hold: the suite runs against a temp
# nucleus root, so nothing it writes can reach the developer's real records.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state
# shellcheck source=../../src/scripts/lib/service-health.sh
. "$REPO_ROOT/src/scripts/lib/service-health.sh"

require_command jq "service-health tests build and inspect JSON records with jq"

state_dir="$(svc_health_state_dir)"
mkdir -p "$state_dir"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

assert_eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# rec <instance> <jq expression> — raw field access direct from the file, so a
# null reads back as `null` rather than as the empty string svc_health_get
# renders it to.  Distinguishing the two is the point of the sentinel section.
rec() { # <instance> <expr>
  jq -r "$2" "$(svc_health_state_file "$1")" 2>/dev/null || printf 'missing'
}

# record_rc <instance> <field> <value> — svc_health_set's status, without
# tripping `set -e` on the failure cases the suite asserts on.
record_rc() { # <instance> <field> <value>
  local _rc=0
  svc_health_set "$1" "$2" "$3" >/dev/null 2>&1 || _rc=$?
  printf '%s' "$_rc"
}

clear_rc() { # <instance>
  local _rc=0
  svc_health_clear "$1" >/dev/null 2>&1 || _rc=$?
  printf '%s' "$_rc"
}

is_blocked_rc() { # <instance>
  local _rc=0
  svc_health_is_blocked "$1" || _rc=$?
  printf '%s' "$_rc"
}

is_reported_rc() { # <instance> <expected>
  local _rc=0
  svc_health_is_reported "$1" "$2" || _rc=$?
  printf '%s' "$_rc"
}

looping_of() { # <instance> — "yes"/"no", the predicate every caller acts on
  if svc_health_is_looping "$1"; then printf 'yes'; else printf 'no'; fi
}

status_of() { svc_health_status "$1"; }

# seed_record <instance> <restartCount> <lastSuccess> — write a canonical record
# whose restarts all sit inside the last hour, so loop-boundary cases are built
# from real timestamps instead of hand-edited JSON.
seed_record() { # <instance> <restartCount> <lastSuccess>
  local instance="$1" count="$2" last_success="$3" now i restarts='[]'
  now=$(date +%s)
  if [ "$count" -gt 0 ]; then
    restarts="$(
      i=0
      while [ "$i" -lt "$count" ]; do
        printf '%s\n' "$((now - 60 * (count - i)))"
        i=$((i + 1))
      done | jq -s '.'
    )"
  fi
  jq -n --argjson r "$restarts" --argjson ls "$last_success" \
    --arg boot "$(svc_health_boot_id)" \
    '{state:"running",class:null,remedy:null,attempts:0,reportedState:null,
      boot:$boot,lastSuccess:$ls,restarts:$r,generation:null,lastExit:0}' \
    >"$(svc_health_state_file "$instance")"
}

# ── Section 1: the canonical record ────────────────────────────────────────
section 1 "Record CRUD: the canonical schema round-trips"

_crud="svc-health-crud"
rm -f "$(svc_health_state_file "$_crud")"
svc_health_init "$_crud"
assert_eq "init creates the record file" "0" \
  "$([ -f "$(svc_health_state_file "$_crud")" ] && printf '0' || printf '1')"

# A reader may index any documented field, so every one must exist from the
# first write — an absent key is a missing field, not a null one.
for _field in state class remedy attempts reportedState boot lastSuccess restarts generation lastExit; do
  if jq -e --arg f "$_field" 'has($f)' "$(svc_health_state_file "$_crud")" >/dev/null 2>&1; then
    assert_pass "the record carries '$_field'"
  else
    assert_fail "the record carries '$_field'" "field absent from a freshly initialised record"
  fi
done
assert_eq "the record has exactly the documented fields" "10" "$(rec "$_crud" 'keys | length')"

assert_eq "a fresh record is stopped" "stopped" "$(rec "$_crud" '.state')"
assert_eq "a fresh record has no class" "null" "$(rec "$_crud" '.class')"
assert_eq "a fresh record has no remedy" "null" "$(rec "$_crud" '.remedy')"
assert_eq "a fresh record has no attempts" "0" "$(rec "$_crud" '.attempts')"
assert_eq "a fresh record has nothing reported" "null" "$(rec "$_crud" '.reportedState')"
assert_eq "a fresh record has no successes" "0" "$(rec "$_crud" '.lastSuccess')"
assert_eq "a fresh record has no restarts" "[]" "$(rec "$_crud" '.restarts')"
assert_eq "a fresh record has no exit" "0" "$(rec "$_crud" '.lastExit')"
assert_eq "a fresh record is stamped with this boot" "$(svc_health_boot_id)" "$(rec "$_crud" '.boot')"

# init is idempotent: an existing record is the authority, not the defaults.
_init_before="$(cat "$(svc_health_state_file "$_crud")")"
svc_health_init "$_crud"
assert_eq "init does not rewrite an existing record" "$_init_before" \
  "$(cat "$(svc_health_state_file "$_crud")")"

assert_eq "a state write succeeds" "0" "$(record_rc "$_crud" state '"running"')"
assert_eq "the state reads back" "running" "$(svc_health_get "$_crud" state)"
assert_eq "a class write succeeds" "0" "$(record_rc "$_crud" class '"fskit-provider"')"
assert_eq "the class reads back" "fskit-provider" "$(svc_health_get "$_crud" class)"
assert_eq "a remedy write succeeds" "0" "$(record_rc "$_crud" remedy '"run repair"')"
assert_eq "the remedy reads back" "run repair" "$(svc_health_get "$_crud" remedy)"
assert_eq "an attempts write succeeds" "0" "$(record_rc "$_crud" attempts 3)"
assert_eq "the attempts reads back" "3" "$(svc_health_get "$_crud" attempts)"
assert_eq "the attempts is stored as a number" "number" "$(rec "$_crud" '.attempts | type')"
assert_eq "a lastExit write succeeds" "0" "$(record_rc "$_crud" lastExit 78)"
assert_eq "the lastExit reads back" "78" "$(svc_health_get "$_crud" lastExit)"
assert_eq "a reportedState write succeeds" "0" "$(record_rc "$_crud" reportedState '"blocked:crash-loop"')"
assert_eq "the reportedState reads back" "blocked:crash-loop" "$(svc_health_get "$_crud" reportedState)"
assert_eq "a generation write succeeds" "0" "$(record_rc "$_crud" generation 7)"
assert_eq "the generation reads back" "7" "$(svc_health_get "$_crud" generation)"

# svc_health_set_state is a quoting wrapper around the same writer, not a
# second writer that could drift from it.
svc_health_set_state "$_crud" "blocked"
assert_eq "set_state stores the unquoted value" "blocked" "$(rec "$_crud" '.state')"
assert_eq "set_state leaves the other fields alone" "fskit-provider" "$(rec "$_crud" '.class')"

assert_eq "read returns the whole record" "blocked" "$(svc_health_read "$_crud" | jq -r '.state')"
svc_health_set_running "$_crud"
assert_eq "set_running records the state" "running" "$(rec "$_crud" '.state')"
assert_eq "set_running clears the class" "null" "$(rec "$_crud" '.class')"
assert_eq "set_running clears the remedy" "null" "$(rec "$_crud" '.remedy')"

assert_eq "reading an unknown instance yields nothing" "" "$(svc_health_get "svc-health-absent" state)"
assert_eq "reading an unknown instance still succeeds" "0" \
  "$(
    svc_health_get "svc-health-absent" state >/dev/null 2>&1
    printf '%s' "$?"
  )"
assert_eq "reading an unknown field yields nothing" "" "$(svc_health_get "$_crud" nosuchfield)"
rm -f "$(svc_health_state_file "$_crud")"

# ── Section 2: the unobserved sentinel ─────────────────────────────────────
section 2 "The unobserved generation sentinel is null, not zero"

# The generation token is the sole input to loop detection, and zero is a
# legitimate reading (systemd reports NRestarts = 0 on a healthy unit), so zero
# cannot double as "never observed" without swallowing a service's first
# restart.  Only a missing value means unobserved.
_sent="svc-health-sentinel"
rm -f "$(svc_health_state_file "$_sent")"
svc_health_init "$_sent"
assert_eq "a fresh record's generation is null" "null" "$(rec "$_sent" '.generation')"
assert_eq "the sentinel is not a zero the token could also hold" "null" "$(rec "$_sent" '.generation | type')"

assert_eq "the null sentinel renders empty to the predicate reader" "" "$(svc_health_get "$_sent" generation)"

# A zero token is storable and must survive as a real observation.
assert_eq "a zero token is storable" "0" "$(record_rc "$_sent" generation 0)"
assert_eq "a stored zero token stays zero" "0" "$(rec "$_sent" '.generation')"
assert_eq "a stored zero token is a number" "number" "$(rec "$_sent" '.generation | type')"
assert_eq "a stored zero token reaches the predicate reader" "0" "$(svc_health_get "$_sent" generation)"
rm -f "$(svc_health_state_file "$_sent")"

# ── Section 3: one loop policy ─────────────────────────────────────────────
section 3 "Loop thresholds come from one policy definition"

assert_eq "the hourly bound is one constant" "10" "$_SVC_HEALTH_LOOP_RESTARTS"
assert_eq "the consecutive bound is one constant" "5" "$_SVC_HEALTH_LOOP_CONSECUTIVE"
assert_eq "the warning bound is one constant" "5" "$_SVC_HEALTH_WARN_RESTARTS"

_loop="svc-health-loop"
_now=$(date +%s)

# Hourly rule, isolated: lastSuccess is newer than every restart, so the
# consecutive rule is silent and only the hourly count can decide.
seed_record "$_loop" "$((_SVC_HEALTH_LOOP_RESTARTS - 1))" "$_now"
assert_eq "one short of the hourly bound does not loop" "no" "$(looping_of "$_loop")"
seed_record "$_loop" "$_SVC_HEALTH_LOOP_RESTARTS" "$_now"
assert_eq "the hourly bound loops" "yes" "$(looping_of "$_loop")"
assert_eq "the hourly bound reports LOOP" "LOOP" "$(status_of "$_loop")"

# Consecutive rule, isolated: no recorded success, so every restart is a
# failure and the faster bound decides.
seed_record "$_loop" "$((_SVC_HEALTH_LOOP_CONSECUTIVE - 1))" 0
assert_eq "one short of the consecutive bound does not loop" "no" "$(looping_of "$_loop")"
seed_record "$_loop" "$_SVC_HEALTH_LOOP_CONSECUTIVE" 0
assert_eq "the consecutive bound loops" "yes" "$(looping_of "$_loop")"
# A formatter that re-implemented the check from the hourly count alone would
# print a rate here, so LOOP is proof the formatter consults the predicate.
assert_eq "the status reflects the consecutive rule, not just the count" "LOOP" "$(status_of "$_loop")"

# Warning band, from the same count.
seed_record "$_loop" "$((_SVC_HEALTH_WARN_RESTARTS - 1))" "$_now"
assert_eq "below the warning bound reports OK" "OK" "$(status_of "$_loop")"
seed_record "$_loop" "$_SVC_HEALTH_WARN_RESTARTS" "$_now"
assert_eq "the warning bound reports the rate" "$_SVC_HEALTH_WARN_RESTARTS/hr" "$(status_of "$_loop")"
assert_eq "the warning band is not yet looping" "no" "$(looping_of "$_loop")"

# The reported status and the enforced predicate must never disagree, at every
# boundary either rule owns.
_disagreements=0
for _n in 0 1 4 5 9 10 11 20; do
  seed_record "$_loop" "$_n" "$_now"
  if [ "$(status_of "$_loop")" = "LOOP" ] && [ "$(looping_of "$_loop")" = "no" ]; then
    _disagreements=$((_disagreements + 1))
  fi
  if [ "$(status_of "$_loop")" != "LOOP" ] && [ "$(looping_of "$_loop")" = "yes" ]; then
    _disagreements=$((_disagreements + 1))
  fi
done
assert_eq "the status never disagrees with the predicate" "0" "$_disagreements"
rm -f "$(svc_health_state_file "$_loop")"

# ── Section 4: blocked, reported, and re-armed ─────────────────────────────
section 4 "Blocked, reported, and re-armed"

_blk="svc-health-blocked"
rm -f "$(svc_health_state_file "$_blk")"
svc_health_set_blocked "$_blk" "crash-loop" "supervisor is restarting the job in a loop"
assert_eq "set_blocked stores the state" "blocked" "$(rec "$_blk" '.state')"
assert_eq "set_blocked stores the class" "crash-loop" "$(rec "$_blk" '.class')"
assert_eq "set_blocked stores the remedy" "supervisor is restarting the job in a loop" "$(rec "$_blk" '.remedy')"
assert_eq "set_blocked stamps the current boot" "$(svc_health_boot_id)" "$(rec "$_blk" '.boot')"
assert_eq "set_blocked clears the reported marker" "null" "$(rec "$_blk" '.reportedState')"
assert_eq "a blocked record is blocked" "0" "$(is_blocked_rc "$_blk")"

assert_eq "nothing is reported before the first report" "1" "$(is_reported_rc "$_blk" "blocked:crash-loop")"
svc_health_mark_reported "$_blk" "blocked:crash-loop"
assert_eq "the report is recorded" "0" "$(is_reported_rc "$_blk" "blocked:crash-loop")"
svc_health_mark_reported "$_blk" "blocked:crash-loop"
assert_eq "re-reporting is idempotent" "0" "$(is_reported_rc "$_blk" "blocked:crash-loop")"
assert_eq "the stored marker survives re-reporting" "blocked:crash-loop" "$(rec "$_blk" '.reportedState')"

# Re-arm.  The state must move AWAY from blocked: a blocked state that survived
# a re-arm is re-reported on every tick forever, and no caller can clear it.
svc_health_clear "$_blk"
assert_eq "clear re-arms the state away from blocked" "stopped" "$(rec "$_blk" '.state')"
assert_eq "a re-armed record is no longer blocked" "1" "$(is_blocked_rc "$_blk")"
assert_eq "clear drops the class" "null" "$(rec "$_blk" '.class')"
assert_eq "clear drops the remedy" "null" "$(rec "$_blk" '.remedy')"
assert_eq "clear drops the reported marker" "null" "$(rec "$_blk" '.reportedState')"
assert_eq "a re-armed record accepts a fresh report" "1" "$(is_reported_rc "$_blk" "blocked:crash-loop")"
assert_eq "clearing an unknown instance succeeds" "0" "$(clear_rc "svc-health-absent")"
rm -f "$(svc_health_state_file "$_blk")"

# ── Section 5: boot freshness ──────────────────────────────────────────────
section 5 "A record from a previous boot is not blocked"

_boot="svc-health-boot"
rm -f "$(svc_health_state_file "$_boot")"
svc_health_set_blocked "$_boot" "crash-loop" "remedy"
assert_eq "a block from this boot is in force" "0" "$(is_blocked_rc "$_boot")"

# Reboot is one of only two ways a block is cleared, so a record still carrying
# the previous boot id must stop gating the service.
jq -c '.boot = "previous-boot"' "$(svc_health_state_file "$_boot")" >"$_tmp/record.json"
mv "$_tmp/record.json" "$(svc_health_state_file "$_boot")"
assert_eq "a block from a previous boot is not in force" "1" "$(is_blocked_rc "$_boot")"
assert_eq "the stale record still reads as blocked" "blocked" "$(rec "$_boot" '.state')"
rm -f "$(svc_health_state_file "$_boot")"

# ── Section 6: re-arming the whole host ───────────────────────────────────
section 6 "the apply-time re-arm clears a block (reset-service-health.sh)"

# The re-arm is the script wired from cloud-drives.nix, not a function in this
# library, so it is exercised as the subprocess apply actually runs.  A blocked
# instance is otherwise cleared only by a reboot, which makes this pass the
# difference between a recoverable and an unrecoverable host.
_rearm_script="$REPO_ROOT/src/scripts/services/reset-service-health.sh"

_ap="svc-health-apply"
rm -f "$(svc_health_state_file "$_ap")"
svc_health_set_blocked "$_ap" "crash-loop" "remedy"
assert_eq "the block is in force before the re-arm" "0" "$(is_blocked_rc "$_ap")"

bash "$_rearm_script" >/dev/null 2>&1
assert_eq "the apply-time re-arm clears the block" "1" "$(is_blocked_rc "$_ap")"
assert_eq "the re-arm removes the record outright" "missing" "$(rec "$_ap" '.state')"

# One unreadable record must not abandon the rest of the pass.
printf '{"state": "blocked"\n' >"$(svc_health_state_file "svc-health-bad")"
svc_health_set_blocked "svc-health-good" "crash-loop" "remedy"
_rearm_rc=0
bash "$_rearm_script" >/dev/null 2>&1 || _rearm_rc=$?
assert_eq "the re-arm reports success with an unreadable record present" "0" "$_rearm_rc"
assert_eq "an unreadable record does not abort the pass" "missing" "$(rec "svc-health-good" '.state')"
rm -f "$(svc_health_state_file "svc-health-bad")"

assert_eq "the re-arm succeeds on a host with no records" "0" \
  "$(
    NUCLEUS_USER_ROOT="$_tmp/empty-root" bash "$_rearm_script" >/dev/null 2>&1
    printf '%s' "$?"
  )"

# ── Section 7: restart recording ───────────────────────────────────────────
section 7 "Restart recording appends, prunes, and feeds the consecutive rule"

_rst="svc-health-restarts"
rm -f "$(svc_health_state_file "$_rst")"
svc_health_init "$_rst"
assert_eq "a fresh record counts no restarts" "0" "$(svc_health_restart_count "$_rst")"
assert_eq "a fresh record has no consecutive failures" "0" "$(svc_health_consecutive_failures "$_rst")"

svc_health_record_restart "$_rst" "relaunch" >/dev/null 2>&1
svc_health_record_restart "$_rst" "relaunch" >/dev/null 2>&1
svc_health_record_restart "$_rst" >/dev/null 2>&1
assert_eq "every recorded restart is kept" "3" "$(rec "$_rst" '.restarts | length')"
assert_eq "the restart rate agrees with the array" "3" "$(svc_health_restart_count "$_rst")"

# Pruning: the array is a one-hour rate window, not a lifetime total, so an
# entry older than the hour is dropped when the next restart is recorded.
_now=$(date +%s)
_stale="$((_now - 7200))"
jq -c --argjson stale "$_stale" --argjson recent "$((_now - 60))" \
  '.restarts = [$stale, $recent]' "$(svc_health_state_file "$_rst")" >"$_tmp/record.json"
mv "$_tmp/record.json" "$(svc_health_state_file "$_rst")"
assert_eq "the stale entry is seeded" "2" "$(rec "$_rst" '.restarts | length')"
svc_health_record_restart "$_rst" >/dev/null 2>&1
assert_eq "an entry older than the hour is pruned" "0" \
  "$(jq --argjson stale "$_stale" '[.restarts[] | select(. == $stale)] | length' "$(svc_health_state_file "$_rst")")"
assert_eq "the window keeps the recent entry and the new one" "2" "$(svc_health_restart_count "$_rst")"

# A record is created on first use, so a caller never has to init first.
rm -f "$(svc_health_state_file "$_rst")"
svc_health_record_restart "$_rst" >/dev/null 2>&1
assert_eq "recording against an absent record creates it" "1" "$(rec "$_rst" '.restarts | length')"

_success_before="$(rec "$_rst" '.lastSuccess')"
svc_health_record_success "$_rst" >/dev/null 2>&1
_success_after="$(rec "$_rst" '.lastSuccess')"
if [ "$_success_after" -gt "$_success_before" ]; then
  assert_pass "recording a success advances lastSuccess"
else
  assert_fail "recording a success advances lastSuccess" "expected > $_success_before, got $_success_after"
fi

# lastSuccess is the divider between the two loop rules: restarts newer than it
# are failures, older ones belong to a healthy life.  A reader that evaluated
# `.lastSuccess` inside the per-restart select would fail on a number and report
# zero for every record, so the failure count is asserted non-zero here.
seed_record "$_rst" 6 "$(date +%s)"
assert_eq "restarts older than the last success are not failures" "0" "$(svc_health_consecutive_failures "$_rst")"
seed_record "$_rst" 6 0
assert_eq "restarts after no recorded success are all failures" "6" "$(svc_health_consecutive_failures "$_rst")"
assert_eq "a failure count past the bound loops" "yes" "$(looping_of "$_rst")"
rm -f "$(svc_health_state_file "$_rst")"

# ── Section 8: a failed write never replaces a good record ─────────────────
section 8 "A failed write never replaces a good record"

_rob="svc-health-robust"
rm -f "$(svc_health_state_file "$_rob")"
svc_health_init "$_rob"
svc_health_set_state "$_rob" "running"
_good="$(cat "$(svc_health_state_file "$_rob")")"

# An unparsable value makes the writer fail; the record must survive untouched
# rather than be replaced by the failed write's output.
assert_eq "a write with an unparsable value reports failure" "1" "$(record_rc "$_rob" state '"unterminated')"
assert_eq "the good record is untouched" "$_good" "$(cat "$(svc_health_state_file "$_rob")")"
assert_eq "the good record still reads back" "running" "$(svc_health_get "$_rob" state)"
assert_eq "a failed write leaves no temporary file behind" "0" \
  "$(find "$state_dir" -maxdepth 1 -name 'svc-health-robust.json.tmp.*' | wc -l | tr -d ' ')"

# A corrupt record is reported, not silently overwritten: its owner is the only
# one who can say what it should have contained.
printf '{"state": "running"\n' >"$(svc_health_state_file "$_rob")"
_corrupt="$(cat "$(svc_health_state_file "$_rob")")"
assert_eq "a write over a corrupt record reports failure" "1" "$(record_rc "$_rob" attempts 1)"
assert_eq "the corrupt record is left alone" "$_corrupt" "$(cat "$(svc_health_state_file "$_rob")")"
assert_eq "clear over a corrupt record reports failure" "1" "$(clear_rc "$_rob")"
assert_eq "clear leaves the corrupt record alone" "$_corrupt" "$(cat "$(svc_health_state_file "$_rob")")"
assert_eq "a failed clear leaves no temporary file behind" "0" \
  "$(find "$state_dir" -maxdepth 1 -name 'svc-health-robust.json.tmp.*' | wc -l | tr -d ' ')"
rm -f "$(svc_health_state_file "$_rob")"

# ── Section 9: the re-arm must disarm the loop detector ─────────────────────
section 9 "A re-arm drops the loop history, so a re-armed instance is not re-blocked"

# WHY: svc_health_is_looping reads .restarts, so a clear that kept the history
# would leave the instance looping while unblocked, and the watchdog's Rule 3
# (live + looping -> block + stop) would re-block it on the very next tick.  A
# re-arm that the watchdog undoes one tick later is not a re-arm.
_rearm="svc-health-rearm"
_now=$(date +%s)
seed_record "$_rearm" "$_SVC_HEALTH_LOOP_RESTARTS" 0
assert_eq "the instance loops before the re-arm" "yes" "$(looping_of "$_rearm")"

svc_health_clear "$_rearm"
assert_eq "clear drops the restart history" "0" "$(rec "$_rearm" '.restarts | length')"
assert_eq "a re-armed instance no longer loops" "no" "$(looping_of "$_rearm")"
assert_eq "the consecutive rule is disarmed too" "0" "$(svc_health_consecutive_failures "$_rearm")"
assert_eq "a re-armed instance does not report LOOP" "OK" "$(status_of "$_rearm")"

# The same must hold for the apply-time entry: the whole point of the pass is
# that a block does not outlive an apply.  It removes the record, so the loop
# history goes with it instead of having to be dropped field by field.
seed_record "$_rearm" "$_SVC_HEALTH_LOOP_RESTARTS" 0
assert_eq "the instance loops again before the re-arm" "yes" "$(looping_of "$_rearm")"
bash "$_rearm_script" >/dev/null 2>&1
assert_eq "the apply-time re-arm leaves no record behind" "missing" "$(rec "$_rearm" '.state')"
assert_eq "the apply-time re-arm leaves the instance un-looped" "no" "$(looping_of "$_rearm")"

# ── Section 10: the boot identity comes from the OS, not a cached file ────
section 10 "The boot identity tracks the OS, so a reboot can clear a block"

# svc_health_boot_id must ASK THE OS on every call.  It previously cached the
# answer in <state dir>/.boot-id and read it back forever, so the value could not
# change across a reboot and the documented reboot-clears-a-block path was
# unreachable.  Only the OS probe is stubbed here — a test cannot reboot the
# host — and every other line runs the real implementation.
_boot_dir="$(svc_health_state_dir)"
rm -f "$_boot_dir/.boot-id"

# A single stub, driven by a variable, so only one definition needs a
# suppression and the two boots differ solely in their value.  Only the OS probe
# is stubbed; svc_health_boot_id and the comparison below are the real ones.
_ostboot="boot-A"
# shellcheck disable=SC2329 # reason: stub consumed indirectly by svc_health_boot_id in the sourced library
svc_health_os_boot_time() { printf '%s' "$_ostboot"; }

_ostboot="boot-A"
assert_eq "the boot identity is boot A while the OS reports boot A" "boot-A" "$(svc_health_boot_id)"

# The regression this section exists for: with the OS now reporting boot B, a
# cached identity would still answer boot A.
_ostboot="boot-B"
assert_eq "the boot identity follows the OS to boot B" "boot-B" "$(svc_health_boot_id)"
assert_eq "the sticky boot-id cache file is gone" "absent" "$([ -e "$_boot_dir/.boot-id" ] && echo present || echo absent)"

# Reboot semantics, driven end to end through the real comparison: a record
# stamped in one boot is in force during it and stops gating in the next.
_reboot="svc-health-reboot"
rm -f "$(svc_health_state_file "$_reboot")"
_ostboot="boot-A"
svc_health_set_blocked "$_reboot" "crash-loop" "remedy"
assert_eq "a boot-A block is in force while the host is in boot A" "0" "$(is_blocked_rc "$_reboot")"
assert_eq "the record is stamped with boot A" "boot-A" "$(rec "$_reboot" '.boot')"
_ostboot="boot-B"
assert_eq "the same record stops gating after the reboot to boot B" "1" "$(is_blocked_rc "$_reboot")"
assert_eq "the record still reads as blocked after the reboot" "blocked" "$(rec "$_reboot" '.state')"

# An unavailable OS boot time must not void the block.  A fabricated value
# (`date +%s`, the old fallback) makes every stored boot look stale, which
# silently drops the loop protection the block exists to provide.
_ostboot=""
assert_eq "an unavailable OS boot time yields the unknown sentinel" "$_SVC_HEALTH_BOOT_UNKNOWN" "$(svc_health_boot_id)"
assert_eq "a block is KEPT when the OS cannot report a boot time" "0" "$(is_blocked_rc "$_reboot")"
rm -f "$(svc_health_state_file "$_reboot")"

finish_tests
