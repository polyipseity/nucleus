#!/usr/bin/env bash
# Store-lock helpers. store_lock_run_bounded runs a command, forwards its output
# untouched, and turns Nix's garbage-collector lock wait into progress plus a
# deadline. The process-group kill is the step runner's, reused here.

# Forwards one stderr line unchanged and marks the seen file once the marker appears.
_store_lock_prefix() {
  local _slp_marker="$1" _slp_seen="$2" _slp_line
  while IFS= read -r _slp_line || [ -n "$_slp_line" ]; do
    printf '%s\n' "$_slp_line" >&2
    case "$_slp_line" in
    *"$_slp_marker"*) printf 'seen\n' >"$_slp_seen" ;;
    esac
  done
}

# Args: $1 deadline seconds (0 disables), $2 progress interval seconds,
#       $3 marker text, $4 seen-file path, then -- and the command.
# Returns the command's status, or 124 when the deadline expires.
store_lock_run_bounded() {
  local _slb_deadline="$1" _slb_interval="$2" _slb_marker="$3" _slb_seen="$4"
  shift 4
  [ "${1:-}" = "--" ] && shift

  case "$_slb_deadline" in
  '' | *[!0-9]*)
    error "store lock deadline must be whole seconds (got '$_slb_deadline')"
    return 2
    ;;
  esac
  case "$_slb_interval" in
  '' | *[!0-9]* | 0) _slb_interval=30 ;;
  esac

  : >"$_slb_seen"
  # WHY a fifo: process substitution is unavailable in some execution contexts
  # (it requires /dev/fd), while a fifo preserves the command's exit status and
  # stdout/stderr separation without a pipeline.
  local _slb_fifo_dir _slb_fifo
  _slb_fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/nucleus-apply-store-lock.XXXXXX")"
  _slb_fifo="$_slb_fifo_dir/stderr.fifo"
  mkfifo "$_slb_fifo"
  _store_lock_prefix "$_slb_marker" "$_slb_seen" <"$_slb_fifo" &
  local _slb_prefix_pid=$!

  # WHY set -m: only with job control does the command get its own process group,
  # so the deadline kills nix and everything it spawned rather than one process.
  if [ "$_slb_deadline" -gt 0 ]; then set -m; fi
  ("$@" 2>"$_slb_fifo") &
  local _slb_pid=$!
  if [ "$_slb_deadline" -gt 0 ]; then set +m; fi

  local _slb_start _slb_elapsed _slb_next="$_slb_interval" _slb_rc=0
  _slb_start="$(date +%s)"
  while kill -0 "$_slb_pid" 2>/dev/null; do
    _slb_elapsed=$(($(date +%s) - _slb_start))
    if [ -s "$_slb_seen" ] && [ "$_slb_elapsed" -ge "$_slb_next" ]; then
      notice "waiting for the Nix store garbage collector lock (elapsed ${_slb_elapsed}s, deadline ${_slb_deadline}s)"
      _slb_next=$((_slb_next + _slb_interval))
    fi
    if [ "$_slb_deadline" -gt 0 ] && [ "$_slb_elapsed" -ge "$_slb_deadline" ]; then
      error "store lock wait exceeded ${_slb_deadline}s; aborting the command (NUCLEUS_STORE_LOCK_DEADLINE)"
      # check-suppress:suppression_doc: the command already outlived its bound; a failing signal must not change the 124 answer
      kill -TERM -- "-$_slb_pid" "$_slb_pid" 2>/dev/null || true
      sleep 1
      # check-suppress:suppression_doc: same as above, and the group may not exist without job control
      kill -KILL -- "-$_slb_pid" "$_slb_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: same as above
      wait "$_slb_pid" 2>/dev/null || true
      # check-suppress:suppression_doc: prefixer exits on fifo EOF after command death; reap failure must not change the 124 answer
      wait "$_slb_prefix_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$_slb_pid" || _slb_rc=$?
  # check-suppress:suppression_doc: prefixer exits on fifo EOF; reap failure must not change the command status
  wait "$_slb_prefix_pid" 2>/dev/null || true
  return "$_slb_rc"
}
