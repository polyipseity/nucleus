#!/usr/bin/env bash
# Bounded nix-collect-garbage runner shared by scripts/gc.sh and the daily
# nix-store-gc service. Reports the Nix GC lock wait, enforces a deadline, and
# passes the command's output through.
#
# Usage: run_nix_gc_with_wait_progress <expiry> [deadline_seconds] [progress_interval_seconds]
#   expiry                    value passed to --delete-older-than
#   deadline_seconds          default ${NUCLEUS_GC_LOCK_WAIT_DEADLINE:-600}, 0 disables
#   progress_interval_seconds default ${NUCLEUS_GC_LOCK_WAIT_PROGRESS_INTERVAL:-30}
run_nix_gc_with_wait_progress() {
  # WHY: nix-collect-garbage can block on the Nix GC lock and emit a single line,
  # so a bounded progress reporter is the only sign that anything is happening.
  _rngc_expiry="$1"
  _rngc_deadline="${2:-${NUCLEUS_GC_LOCK_WAIT_DEADLINE:-600}}"
  _rngc_interval="${3:-${NUCLEUS_GC_LOCK_WAIT_PROGRESS_INTERVAL:-30}}"
  _rngc_bin="${NUCLEUS_NIX_COLLECT_GARBAGE_BIN:-nix-collect-garbage}"
  _rngc_lock_msg="waiting for the big garbage collector lock"
  _rngc_saw_lock=false
  _rngc_last_progress=0
  _rngc_rc=0

  case "$_rngc_deadline" in
  '' | *[!0-9-]*)
    _rngc_deadline=600
    ;;
  esac
  case "$_rngc_interval" in
  '' | *[!0-9]* | 0)
    _rngc_interval=30
    ;;
  esac

  _rngc_start="$(date +%s)"
  _rngc_fifo="$(mktemp "${TMPDIR:-/tmp}/nucleus-gc-wait.XXXXXX")"
  rm -f "$_rngc_fifo"
  mkfifo "$_rngc_fifo"

  "$_rngc_bin" --delete-older-than "$_rngc_expiry" >"$_rngc_fifo" 2>&1 &
  _rngc_pid=$!

  exec 3<"$_rngc_fifo"
  while kill -0 "$_rngc_pid" 2>/dev/null; do
    _rngc_read_rc=0
    IFS= read -r -t 1 _rngc_line <&3 || _rngc_read_rc=$?
    if [ "$_rngc_read_rc" -eq 0 ] || { [ "$_rngc_read_rc" -eq 1 ] && [ -n "${_rngc_line:-}" ]; }; then
      printf '%s\n' "$_rngc_line"
      case "$_rngc_line" in
      *"$_rngc_lock_msg"*)
        _rngc_saw_lock=true
        ;;
      esac
    fi
    _rngc_now="$(date +%s)"
    _rngc_elapsed=$((_rngc_now - _rngc_start))
    if [ "$_rngc_saw_lock" = true ] && [ "$_rngc_elapsed" -ge $((_rngc_last_progress + _rngc_interval)) ]; then
      say "waiting for the Nix garbage collector lock (elapsed ${_rngc_elapsed}s)"
      _rngc_last_progress="$_rngc_elapsed"
    fi
    if [ "$_rngc_deadline" -gt 0 ] && [ "$_rngc_elapsed" -ge "$_rngc_deadline" ]; then
      warn "timed out waiting for nix-collect-garbage after ${_rngc_elapsed}s (Nix garbage collector lock)"
      # check-suppress:suppression_doc: best-effort termination after GC lock wait deadline
      kill "$_rngc_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: reap terminated gc process after deadline expiry
      wait "$_rngc_pid" 2>/dev/null || true
      exec 3<&-
      rm -f "$_rngc_fifo"
      return 1
    fi
  done

  # check-suppress:suppression_doc: drain buffered output after gc process exit
  while IFS= read -r _rngc_line <&3 || {
    [ -n "${_rngc_line:-}" ] && printf '%s\n' "$_rngc_line"
    false
  }; do
    printf '%s\n' "$_rngc_line"
    # check-suppress:suppression_doc: read returns non-zero at EOF after the last buffered line is drained
  done || true
  exec 3<&-
  rm -f "$_rngc_fifo"
  wait "$_rngc_pid" || _rngc_rc=$?
  return "$_rngc_rc"
}
