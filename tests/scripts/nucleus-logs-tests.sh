#!/usr/bin/env bash
# Tests for scripts/logs.sh: the append-only JSONL event log, its concurrency
# contract, and the rotation and expiry it owns.
#
# The concurrency case is the load-bearing one. A writer that truncates, that
# opens without O_APPEND, or that spends more than one write(2) per line loses or
# interleaves lines under contention, and nothing else in the tree would notice.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
LOGS_SH="$REPO_ROOT/scripts/logs.sh"
readonly REPO_ROOT LOGS_SH

init_test_state
ensure_safe_rm_env
require_command jq "nucleus-logs writes and reads JSON events"
require_command gzip "nucleus-logs compresses rotated archives"

_WORK="$(mktemp -d)"
export NUCLEUS_LOG_DIR="$_WORK"
trap 'rm -rf "$_WORK"' EXIT

_ALL_KEYS='"ts","id","kind","harness","decision","source","filter","rule","latency_ms","summary","digest"'

# logs <args...>: run the app against the suite's temporary log root.
logs() {
  NUCLEUS_LOG_DIR="$_WORK" bash "$LOGS_SH" "$@"
}

# ---- One append produces one canonical line ----

test_append_writes_one_canonical_line() {
  printf '%s\n' '{"id":"one","kind":"decision"}' | logs append decisions
  local count
  count="$(wc -l <"$_WORK/decisions.log" | tr -d ' ')"
  if [ "$count" -eq 1 ]; then
    assert_pass "append writes exactly one line"
  else
    assert_fail "append-one-line" "expected 1 line, got $count"
  fi

  local missing
  missing="$(jq -r --argjson keys "[$_ALL_KEYS]" '. as $event | [$keys[] as $k | select($event | has($k) | not) | $k] | join(",")' "$_WORK/decisions.log")"
  if [ -z "$missing" ]; then
    assert_pass "append carries all eleven canonical keys"
  else
    assert_fail "append-keys" "missing keys: $missing"
  fi

  if [ "$(jq -r '.id' "$_WORK/decisions.log")" = "one" ]; then
    assert_pass "append preserves the supplied id"
  else
    assert_fail "append-id" "id not preserved: $(cat "$_WORK/decisions.log")"
  fi
}

# ---- Oversized events are refused, not truncated ----

test_oversized_event_is_refused() {
  local big status=0
  big="$(printf 'x%.0s' $(seq 5000))"
  printf '{"id":"big","summary":"%s"}\n' "$big" | logs append decisions >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    assert_pass "an event over 4096 bytes is rejected"
  else
    assert_fail "append-oversize" "append accepted an oversized event"
  fi

  if ! jq -e 'select(.id == "big")' "$_WORK/decisions.log" >/dev/null; then
    assert_pass "a rejected event leaves no partial line"
  else
    assert_fail "append-oversize-partial" "oversized event reached the log"
  fi
}

# ---- 50 concurrent appends: no lost line, no interleaved line ----

test_concurrent_appends_keep_every_line() {
  local appended i
  cp "$_WORK/decisions.log" "$_WORK/decisions.before"

  for i in $(seq 1 50); do
    printf '{"id":"c%02d","kind":"concurrent","summary":"line %02d"}\n' "$i" "$i" |
      NUCLEUS_LOG_DIR="$_WORK" bash "$LOGS_SH" append concurrent &
  done
  wait

  after="$(wc -l <"$_WORK/concurrent.log" | tr -d ' ')"
  appended=$((after))
  if [ "$appended" -eq 50 ]; then
    assert_pass "50 concurrent appends produce exactly 50 lines"
  else
    assert_fail "append-concurrent-count" "expected 50 lines, got $appended"
  fi

  local invalid
  invalid="$(jq -c 'select((.id | type) != "string" or (.summary | type) != "string")' "$_WORK/concurrent.log" | wc -l | tr -d ' ')"
  if [ "$invalid" -eq 0 ]; then
    assert_pass "every concurrent line parses with its own id and summary"
  else
    assert_fail "append-concurrent-interleave" "$invalid interleaved or unparseable line(s)"
  fi

  local unique
  unique="$(jq -r '.id' "$_WORK/concurrent.log" | sort -u | wc -l | tr -d ' ')"
  if [ "$unique" -eq 50 ]; then
    assert_pass "all 50 concurrent ids are present exactly once"
  else
    assert_fail "append-concurrent-unique" "expected 50 distinct ids, got $unique"
  fi

  # WHY compare the same file: the earlier assertion compared decisions.log
  # before with concurrent.log after, so it could never fail for the reason it
  # claims. The snapshot is taken before the concurrent writes and must survive
  # them byte for byte.
  if cmp -s "$_WORK/decisions.before" "$_WORK/decisions.log"; then
    assert_pass "concurrent appends left the neighbouring log byte-identical"
  else
    assert_fail "append-append-only" "concurrent appends rewrote decisions.log"
  fi
}

# ---- label appends an event and never rewrites history ----

test_label_appends_verdict_event() {
  logs label seed correct --note "seed event"
  cp "$_WORK/harness.log" "$_WORK/harness.before"

  logs label one false-allow --note "reviewed by hand"

  # WHY a seeded snapshot: the seed gives the prefix a line to compare, so the
  # assertion can fail when label rewrites history instead of only when the file
  # is missing.
  if head -n "$(wc -l <"$_WORK/harness.before" | tr -d ' ')" "$_WORK/harness.log" | cmp -s - "$_WORK/harness.before"; then
    assert_pass "label appends without rewriting the earlier harness lines"
  else
    assert_fail "label-rewrite" "label modified an existing line"
  fi

  local event
  event="$(jq -rc 'select(.kind == "label" and .id == "one") | [.verdict, .note, .source]' "$_WORK/harness.log" | tail -n 1)"
  if [ "$event" = '["false-allow","reviewed by hand","none"]' ]; then
    assert_pass "label records verdict, note, and source=none in the harness log"
  else
    assert_fail "label-verdict" "unexpected label event: $event"
  fi
}

# ---- label takes a target log and enforces the verdict vocabulary ----

test_label_target_and_verdict_vocabulary() {
  printf '%s\n' '{"id":"t1","kind":"decision"}' | logs append other
  logs label t1 correct --log other --note "agrees"

  if [ "$(jq -r 'select(.kind == "label") | .id' "$_WORK/other.log" | tail -n 1)" = "t1" ]; then
    assert_pass "label --log appends to the named log"
  else
    assert_fail "label-log" "label did not reach other.log"
  fi

  local status=0
  logs label t1 maybe >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    assert_pass "label rejects a verdict outside correct/false-allow/false-deny"
  else
    assert_fail "label-bad-verdict" "label accepted an unknown verdict"
  fi
}

# ---- a blank log name never resolves to a path ----

test_blank_name_is_rejected() {
  local status=0
  printf '{"id":"x"}\n' | logs append '   ' >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    assert_pass "a whitespace-only log name is rejected"
  else
    assert_fail "append-blank-name" "append accepted a whitespace-only name"
  fi

  if [ ! -e "$_WORK/.log" ] && [ ! -e "$_WORK/.lock" ]; then
    assert_pass "a rejected name leaves no path behind"
  else
    assert_fail "append-blank-path" "a rejected name created a path"
  fi
}

# ---- rotate copies, compresses, and truncates in place ----

test_rotate_archives_and_truncates() {
  local big
  big="$(printf 'y%.0s' $(seq 3000))"
  printf '{"id":"rot","summary":"%s"}\n' "$big" >>"$_WORK/rotate-me.log"

  logs rotate --max-size 1024 --max-files 4 --compress true

  if [ -f "$_WORK/rotate-me.log.1.gz" ]; then
    assert_pass "rotate produces rotate-me.log.1.gz"
  else
    assert_fail "rotate-archive" "no rotate-me.log.1.gz after rotate"
  fi

  local size
  size="$(wc -c <"$_WORK/rotate-me.log" | tr -d ' ')"
  if [ "$size" -eq 0 ]; then
    assert_pass "rotate truncates the live file in place"
  else
    assert_fail "rotate-truncate" "live file still $size bytes"
  fi

  if [ "$(gzip -dc "$_WORK/rotate-me.log.1.gz" | jq -r '.id')" = "rot" ]; then
    assert_pass "the archive holds the rotated event"
  else
    assert_fail "rotate-content" "archive content lost the event"
  fi
}

# ---- rotate without compression leaves a plain archive that show still reads ----

test_rotate_without_compression_is_readable() {
  local big
  big="$(printf 'w%.0s' $(seq 3000))"
  printf '{"id":"plain","summary":"%s"}\n' "$big" >>"$_WORK/plain.log"

  logs rotate --max-size 1024 --max-files 4 --compress false

  if [ -f "$_WORK/plain.log.1" ]; then
    assert_pass "rotate without compression leaves a plain archive"
  else
    assert_fail "rotate-plain" "no plain archive after rotate --compress false"
  fi

  if [ "$(logs show plain --json | jq -r '.[].id' | head -n 1)" = "plain" ]; then
    assert_pass "show reads an uncompressed archive"
  else
    assert_fail "rotate-plain-show" "show did not return the archived event"
  fi
}

# ---- expire removes archives past the retention window ----

test_expire_removes_old_archives() {
  printf '{"id":"old"}\n' | gzip >"$_WORK/expire-me.log.1.gz"
  printf '{"id":"fresh"}\n' | gzip >"$_WORK/expire-me.log.2.gz"
  touch -t 202001010000 "$_WORK/expire-me.log.1.gz"

  logs expire --expiry 7d

  if [ ! -f "$_WORK/expire-me.log.1.gz" ]; then
    assert_pass "expire removes an archive older than the expiry"
  else
    assert_fail "expire-old" "the expired archive survived"
  fi

  if [ -f "$_WORK/expire-me.log.2.gz" ]; then
    assert_pass "expire keeps an archive inside the expiry"
  else
    assert_fail "expire-fresh" "expire removed a fresh archive"
  fi
}

# ---- show and stats read what append wrote ----

test_show_filters_by_kind() {
  local output
  output="$(logs show harness --kind label --json)"
  if printf '%s' "$output" | jq -e 'length >= 1 and all(.kind == "label")' >/dev/null; then
    assert_pass "show --kind returns only matching events"
  else
    assert_fail "show-kind" "unexpected show output: $output"
  fi
}

# ---- Run tests ----

section 1 "nucleus-logs"
echo ""

test_append_writes_one_canonical_line
test_oversized_event_is_refused
test_concurrent_appends_keep_every_line
test_label_appends_verdict_event
test_label_target_and_verdict_vocabulary
test_blank_name_is_rejected
test_rotate_archives_and_truncates
test_rotate_without_compression_is_readable
test_expire_removes_old_archives
test_show_filters_by_kind

finish_tests
