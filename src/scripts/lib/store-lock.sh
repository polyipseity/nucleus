#!/usr/bin/env bash
# Store-lock helpers. store_lock_run_bounded runs a command, forwards its output
# untouched, and turns Nix's garbage-collector lock wait into progress plus a
# deadline. The process-group kill is the step runner's, reused here.

_NUCLEUS_STORE_LOCK_SOURCED=1

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

# Converts an etime/time field to whole seconds. Accepts MM:SS, HH:MM:SS,
# D-HH:MM:SS, and the CPU form MM:SS.ss.
_store_lock_epoch_to_seconds() {
  local _sls_value="$1" _sls_days=0 _sls_a=0 _sls_b=0 _sls_c=0
  case "$_sls_value" in
  *-*)
    _sls_days="${_sls_value%%-*}"
    _sls_value="${_sls_value#*-}"
    ;;
  esac
  IFS=: read -r _sls_a _sls_b _sls_c <<<"$_sls_value"
  if [ -z "$_sls_c" ]; then
    _sls_c="$_sls_b"
    _sls_b="$_sls_a"
    _sls_a=0
  fi
  _sls_c="${_sls_c%%.*}"
  printf '%s\n' $((10#${_sls_days:-0} * 86400 + 10#${_sls_a:-0} * 3600 + 10#${_sls_b:-0} * 60 + 10#${_sls_c:-0}))
}

# Prints "<pid> <cpu_seconds> <command>" for every collection candidate.
_store_lock_candidate_rows() {
  ps -axo pid=,etime=,time=,command= |
    while read -r _slr_pid _slr_etime _slr_time _slr_command; do
      case "$_slr_command" in
      *"nix store gc"* | *nix-collect-garbage* | *"nix-store --gc"* | *"nix-store -gc"*) ;;
      *) continue ;;
      esac
      case "$_slr_command" in
      *--dry-run* | *--print-dead*) continue ;;
      esac
      printf '%s %s %s %s\n' "$_slr_pid" "$(_store_lock_epoch_to_seconds "$_slr_etime")" \
        "$(_store_lock_epoch_to_seconds "$_slr_time")" "$_slr_command"
    done
}

# Args: $1 state dir, $2 stall seconds, $3 reclaim grace seconds, $4 cooldown seconds.
store_lock_watchdog_tick() {
  local _slw_dir="$1" _slw_stall="${2:-3600}" _slw_grace="${3:-30}" _slw_cooldown="${4:-21600}"
  local _slw_now _slw_pid _slw_age _slw_cpu _slw_command
  local _slw_record _slw_prev_cpu _slw_last_reclaim _slw_cooldown_until

  mkdir -p "$_slw_dir"
  _slw_now="$(date +%s)"

  while read -r _slw_pid _slw_age _slw_cpu _slw_command; do
    [ -n "$_slw_pid" ] || continue
    _slw_record="$_slw_dir/$_slw_pid"
    if [ ! -f "$_slw_record" ]; then
      printf '%s %s 0\n' "$_slw_cpu" "$_slw_now" >"$_slw_record"
      continue
    fi
    read -r _slw_prev_cpu _ _slw_last_reclaim <"$_slw_record" || {
      _slw_prev_cpu=0
      _slw_last_reclaim=0
    }
    _slw_last_reclaim="${_slw_last_reclaim:-0}"
    printf '%s %s %s\n' "$_slw_cpu" "$_slw_now" "$_slw_last_reclaim" >"$_slw_record"

    if [ "$_slw_age" -lt "$_slw_stall" ]; then continue; fi
    if [ "$_slw_cpu" -gt "$_slw_prev_cpu" ]; then continue; fi

    _slw_cooldown_until=$((_slw_last_reclaim + _slw_cooldown))
    if [ "$_slw_last_reclaim" -gt 0 ] && [ "$_slw_cooldown_until" -gt "$_slw_now" ]; then
      notice "store collection $_slw_pid (${_slw_age}s old) looks stalled, but its reclaim cooldown is active until $(date -r "$_slw_cooldown_until" '+%H:%M' 2>/dev/null || date -d "@$_slw_cooldown_until" '+%H:%M' 2>/dev/null || printf '%s' "$_slw_cooldown_until"); leaving it alone"
      continue
    fi

    warn "store collection $_slw_pid stalled for ${_slw_age}s with no CPU progress ($_slw_command); sending SIGTERM"
    kill -TERM "$_slw_pid" 2>/dev/null || warn "store collection $_slw_pid refused SIGTERM"
    local _slw_waited=0
    while [ "$_slw_waited" -lt "$_slw_grace" ] && kill -0 "$_slw_pid" 2>/dev/null; do
      sleep 1
      _slw_waited=$((_slw_waited + 1))
    done
    if kill -0 "$_slw_pid" 2>/dev/null; then
      warn "store collection $_slw_pid ignored SIGTERM for ${_slw_grace}s; sending SIGKILL"
      kill -KILL "$_slw_pid" 2>/dev/null || warn "store collection $_slw_pid vanished before SIGKILL"
    fi
    printf '%s %s %s\n' "$_slw_cpu" "$_slw_now" "$_slw_now" >"$_slw_record"
  done < <(_store_lock_candidate_rows)

  # Drop state for pids that are gone, so the directory cannot grow without end.
  # Keep dead-pid records while their reclaim cooldown is active, otherwise a
  # reclaimed pid that disappears before the next tick loses its cooldown.
  local _slw_stale _slw_stale_pid _slw_stale_lr
  for _slw_stale in "$_slw_dir"/*; do
    [ -f "$_slw_stale" ] || continue
    case "$_slw_stale" in */last-reclaim)
      rm -f "$_slw_stale"
      continue
      ;;
    esac
    _slw_stale_pid="$(basename "$_slw_stale")"
    if kill -0 "$_slw_stale_pid" 2>/dev/null; then
      continue
    fi
    read -r _ _ _slw_stale_lr <"$_slw_stale" || _slw_stale_lr=0
    _slw_stale_lr="${_slw_stale_lr:-0}"
    if [ "$_slw_stale_lr" -gt 0 ] && [ $((_slw_stale_lr + _slw_cooldown)) -gt "$_slw_now" ]; then
      continue
    fi
    rm -f "$_slw_stale"
  done
}
