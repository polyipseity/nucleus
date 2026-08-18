#!/usr/bin/env bash
# Step runner library for check and test orchestrators.
# Provides step registration, execution, timing, and aggregation.
# Sourced by check-lib.sh and test-lib.sh.
#
# Guard against re-sourcing — step files source independently and
# re-sourcing would wipe step registration arrays, leaving only the last step.
[ -n "${_NUCLEUS_STEP_RUNNER_SOURCED-}" ] && return
_NUCLEUS_STEP_RUNNER_SOURCED=1

# shellcheck source=./deny-list.sh
# Self-derived dir: do NOT rely on ambient SCRIPT_DIR — test harnesses source
# this file from their own directories, and a wrong path would print
# "No such file or directory" for every subshell invocation.
_NUCLEUS_STEP_RUNNER_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$_NUCLEUS_STEP_RUNNER_DIR/deny-list.sh"

# shellcheck source=./lib.sh
. "$_NUCLEUS_STEP_RUNNER_DIR/lib.sh"

# --- Step registration ---
# Indexed arrays: step numbers, step names, step function names.
declare -a _STEP_IDS=()
declare -a _STEP_NUMBERS=()
declare -a _STEP_NAMES=()
declare -a _STEP_FUNCS=()

register_step() {
  local _id _n _name _func _base

  case "$#" in
  3)
    # Derive the step number from the caller file's NN- filename prefix.
    _id="$1" _name="$2" _func="$3"
    if [ -z "${BASH_SOURCE[1]:-}" ]; then
      printf '%s\n' "register_step: cannot derive step number from '' (expected NN- prefix); pass the number explicitly" >&2
      return 1
    fi
    _base=$(basename -- "${BASH_SOURCE[1]}")
    case "$_base" in
    [0-9][0-9]-*)
      _n="${_base%%-*}"
      ;;
    *)
      printf '%s\n' "register_step: cannot derive step number from '${BASH_SOURCE[1]}' (expected NN- prefix); pass the number explicitly" >&2
      return 1
      ;;
    esac
    ;;
  4)
    _id="$1" _n="$2" _name="$3" _func="$4"
    ;;
  *)
    printf '%s\n' "register_step: expected 3 or 4 arguments (id [number] name func), got $#: $*" >&2
    return 1
    ;;
  esac

  if [ -z "$_id" ]; then
    error "Step ID must not be empty"
    exit 1
  fi

  if echo "$_id" | grep -q '[0-9]'; then
    error "Step ID '$_id' contains forbidden digit"
    exit 1
  fi

  local _existing_id
  for _existing_id in ${_STEP_IDS[@]+"${_STEP_IDS[@]}"}; do
    if [ "$_existing_id" = "$_id" ]; then
      error "Duplicate step ID '$_id'"
      exit 1
    fi
  done

  if ! [[ "$_n" =~ ^[0-9]+$ ]] || [ "$_n" -eq 0 ] 2>/dev/null; then
    error "Step number '$_n' must be a positive integer"
    exit 1
  fi

  local _existing_n
  for _existing_n in ${_STEP_NUMBERS[@]+"${_STEP_NUMBERS[@]}"}; do
    if [ "$_existing_n" -eq "$_n" ] 2>/dev/null; then
      error "Duplicate step number $_n"
      exit 1
    fi
  done

  _STEP_IDS+=("$_id")
  _STEP_NUMBERS+=("$_n")
  _STEP_NAMES+=("$_name")
  _STEP_FUNCS+=("$_func")
}

# step_number — print the number of the enclosing registered step (for skip messages).
# Works at any call depth: walks FUNCNAME and returns the first frame registered in
# _STEP_FUNCS. Outputs nothing and returns 1 when called outside a step function.
step_number() {
  local _i _j
  for ((_i = 1; _i < ${#FUNCNAME[@]}; _i++)); do
    for _j in "${!_STEP_FUNCS[@]}"; do
      if [ "${FUNCNAME[$_i]}" = "${_STEP_FUNCS[$_j]}" ]; then
        printf '%s\n' "${_STEP_NUMBERS[$_j]}"
        return 0
      fi
    done
  done
  return 1
}

# --- Wave parallelism infrastructure ---
# Each step writes .exit, .time, .name files to _wave_tmpdir.
# Results are aggregated at the end.
_wave_tmpdir=""
_wave_tmpdir_created=false

_wave_cleanup_stale() {
  local _d _pid
  for _d in "${TMPDIR:-/tmp}/nucleus-step-runner-"*; do
    [ -d "$_d" ] || continue                  # check-suppress:suppression_doc: glob may expand to literal pattern when no matches; [ -d ] check filters it
    _pid=$(cat "$_d/pid" 2>/dev/null || true) # check-suppress:suppression_doc: pid file may not exist yet; empty pid handled below
    if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
      rm -rf "$_d"
    fi
  done
}

_wave_init() {
  _wave_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nucleus-step-runner-XXXXXX") || {
    error "failed to create wave temp directory"
    exit 1
  }
  _wave_tmpdir_created=true
  printf '%s' "$$" >"$_wave_tmpdir/pid"
  trap '_wave_cleanup; exit' INT TERM
  trap '_wave_cleanup' EXIT
}

_wave_cleanup() {
  if $_wave_tmpdir_created && [ -n "$_wave_tmpdir" ]; then
    rm -rf -- "$_wave_tmpdir"
  fi
}

# --- Nix lock ---
# ref: step-runner.instructions.md
NUCLEUS_NIX_LOCK="${TMPDIR:-/tmp}/nucleus-nix.lock"

nucleus_nix_locked() {
  local _lock_dir="$NUCLEUS_NIX_LOCK"
  local _lock_owner=""
  local _lock_waited=0
  local _lock_ret=0

  while ! mkdir "$_lock_dir" 2>/dev/null; do
    _lock_owner="$(cat "$_lock_dir/pid" 2>/dev/null || true)" # check-suppress:suppression_doc: the pid file may be absent; an empty owner falls through to stale-lock recovery
    if [ -z "$_lock_owner" ] || ! kill -0 "$_lock_owner" 2>/dev/null; then
      rm -rf "$_lock_dir"
      continue
    fi
    _lock_waited=$((_lock_waited + 1))
    if [ "$_lock_waited" -ge 1800 ]; then
      error "timed out waiting for nix lock $_lock_dir (owner PID $_lock_owner)"
      return 1
    fi
    sleep 1
  done
  printf '%s\n' "$BASHPID" >"$_lock_dir/pid"

  if "$@"; then
    _lock_ret=0
  else
    _lock_ret=$?
  fi
  rm -rf "$_lock_dir"
  return "$_lock_ret"
}

# Defaults for when parse_args hasn't been called (e.g. unit tests that source
# this library directly). run_all_steps reads all three eagerly while building
# the step context, so they must always be bound under `set -u`.
HAS_ARGS=${HAS_ARGS:-false}
FAIL_FAST=${FAIL_FAST:-false}
ONLINE=${ONLINE:-false}

_step_now_ms() {
  if [ -n "${EPOCHREALTIME-}" ]; then
    awk -v t="$EPOCHREALTIME" 'BEGIN { printf "%d\n", int(t * 1000) }'
    return
  fi
  case "$(uname -s)" in
  Darwin)
    perl -MTime::HiRes=time -e 'printf "%d\n", int(time() * 1000)'
    ;;
  *)
    date +%s%3N
    ;;
  esac
}

_format_duration_s() {
  awk -v ms="${1:-0}" 'BEGIN { printf "%.3f s", ms / 1000 }'
}

# --- _run_step wrapper ---
_run_step() {
  local _n="$1" _name="$2" _func="$3"
  shift 3
  local _step_start_ms _elapsed_ms _exit_code _fifo

  _step_start_ms=$(_step_now_ms)

  printf '\n=== [%s] %s ===\n' "$_n" "$_name" >"$_wave_tmpdir/step-$_n.out"
  printf '%s' "$_name" >"$_wave_tmpdir/step-$_n.name"

  _fifo=$(mktemp -u "${TMPDIR:-/tmp}/nucleus-step-${_n}-XXXXXX")
  mkfifo "$_fifo"
  (
    if "$_func" "STEP_CTX" "$@"; then
      exit 0
    else
      exit $?
    fi
  ) >"$_fifo" 2>&1 &
  local _func_pid=$!

  tee -a "$_wave_tmpdir/step-$_n.out" <"$_fifo" | while IFS= read -r _line || [ -n "$_line" ]; do
    # _n is the zero-padded NN- prefix string; 10# forces decimal so %d doesn't parse it as octal.
    printf '%s[step %2d]%s %s\n' "${_nuc_c2_dim}" "$((10#${_n}))" "${_nuc_c2_reset}" "$_line" >&2
  done

  _exit_code=0
  wait "$_func_pid" || _exit_code=$?
  rm -f "$_fifo"

  printf '%s' "$_exit_code" >"$_wave_tmpdir/step-$_n.exit"
  _elapsed_ms=$(($(_step_now_ms) - _step_start_ms))
  printf '%s' "$_elapsed_ms" >"$_wave_tmpdir/step-$_n.time"

  if [ "$_exit_code" -ne 0 ] && [ "$_exit_code" -ne 2 ] && $FAIL_FAST; then
    exit "$_exit_code"
  fi
}

# --- _run_skipped_step helper ---
_run_skipped_step() {
  local _n="$1" _name="$2" _id="$3"
  local _step_start_ms _elapsed_ms

  _step_start_ms=$(_step_now_ms)

  printf '\n=== [%s] %s === SKIPPED (--skip-steps: %s)\n' "$_n" "$_name" "$_id" >"$_wave_tmpdir/step-$_n.out"
  printf '%s' "$_name" >"$_wave_tmpdir/step-$_n.name"
  printf '%s' "2" >"$_wave_tmpdir/step-$_n.exit"
  _elapsed_ms=$(($(_step_now_ms) - _step_start_ms))
  printf '%s' "$_elapsed_ms" >"$_wave_tmpdir/step-$_n.time"
}

# skip_step — Print a skip header to stdout (F3 with SKIPPED suffix). Used by step
# scripts for runtime self-skips (scoped mode with no matching files). Display-only;
# the runner's own skip path writes the step files and exit-code marker.
skip_step() {
  printf '\n%s=== [%s] %s === SKIPPED (%s)%s\n' "${_nuc_c1_bold}${_nuc_c1_cyan}" "$1" "$2" "$3" "${_nuc_c1_reset}"
}

# --- Argument parsing ---
parse_args() {
  ONLINE=false
  SCOPED=false
  FULL=false
  HAS_ARGS=false
  POSITIONAL_ARGS=()
  SKIP_STEPS=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
      ;;
    --no-fail-fast)
      FAIL_FAST=false
      shift
      ;;
    --scoped)
      SCOPED=true
      shift
      ;;
    --full)
      FULL=true
      shift
      ;;
    --online)
      # shellcheck disable=SC2034 # reason: consumed by check step 13 (online-determinism) via transitive sourcing
      ONLINE=true
      shift
      ;;
    --skip-steps=*)
      SKIP_STEPS=()
      local _val="${1#--skip-steps=}"
      if [ -n "$_val" ]; then
        local _old_ifs="$IFS"
        IFS=','
        for _part in $_val; do
          _part="${_part## }"
          _part="${_part%% }"
          if [ -n "$_part" ]; then
            local _already=false
            for _existing in "${SKIP_STEPS[@]}"; do
              [ "$_existing" = "$_part" ] && _already=true && break
            done
            $_already || SKIP_STEPS+=("$_part")
          fi
        done
        IFS="$_old_ifs"
      fi
      shift
      ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
    esac
  done

  if "$SCOPED" && "$FULL"; then
    error "cannot specify both --scoped and --full"
    usage >&2
    exit 1
  fi

  [ "$#" -gt 0 ] && HAS_ARGS=true
  if $SCOPED; then
    HAS_ARGS=true
  fi
  if $FULL; then
    HAS_ARGS=false
  fi

  POSITIONAL_ARGS=("$@")

  SH_FILES=()
  PS1_FILES=()
  PKR_FILES=()
  NIX_FILES=()
  if $HAS_ARGS; then
    for _f in "$@"; do
      case "$_f" in
      *.sh) SH_FILES+=("$_f") ;;
      *.ps1) PS1_FILES+=("$_f") ;;
      *.pkr.hcl) PKR_FILES+=("$_f") ;;
      *.nix) NIX_FILES+=("$_f") ;;
      esac
    done
  fi
}

# --- File caching ---
cache_file_lists() {
  # shellcheck disable=SC2034 # reason: consumed by step files (04, 11) via transitive sourcing
  readarray -t CACHED_NIX_FILES < <(
    find . -path ./vendor -prune -false -o -name '*.nix' -print |
      filter_gitignored |
      sort
  ) # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step files (07, 09) via transitive sourcing
  readarray -t CACHED_YAML_FILES < <(
    find . -not -path '*/vendor/*' \( -name '*.yml' -o -name '*.yaml' \) -print |
      filter_gitignored |
      sort
  ) # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step files (07) via transitive sourcing
  readarray -t CACHED_JSON_FILES < <(
    find src -name '*.json' -not -path '*/vendor/*' -not -name '*.schema.json' -print |
      filter_gitignored |
      sort
  ) # ref: allow-and-deny-lists.instructions.md#A7,#B7 -- schema files are meta; vendor is structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step files (11) via transitive sourcing
  readarray -t CACHED_SHELL_FILES < <(
    find . -path ./vendor -prune -false -o -name '*.sh' -print |
      filter_gitignored |
      sort
  )
}

# --- run_all_steps ---
run_all_steps() {
  _wave_cleanup_stale
  _wave_init
  cache_file_lists

  # Build the shared context object once; every step receives it explicitly as
  # its first argument (the name of this assoc array) so no step reads enclosing
  # globals. Subshells copy the parent's variables, but explicit context keeps
  # the contract identical to the PowerShell runner and removes ambient reads.
  local -A STEP_CTX=()
  STEP_CTX[HAS_ARGS]="$HAS_ARGS"
  STEP_CTX[REPO_ROOT]="$REPO_ROOT"
  STEP_CTX[_wave_tmpdir]="$_wave_tmpdir"
  STEP_CTX[FAIL_FAST]="$FAIL_FAST"
  STEP_CTX[SKIP_STEPS]="SKIP_STEPS"
  STEP_CTX[ONLINE]="$ONLINE"
  STEP_CTX[SH_FILES]="SH_FILES"
  STEP_CTX[PS1_FILES]="PS1_FILES"
  STEP_CTX[PKR_FILES]="PKR_FILES"
  STEP_CTX[NIX_FILES]="NIX_FILES"
  STEP_CTX[CACHED_NIX_FILES]="CACHED_NIX_FILES"
  STEP_CTX[CACHED_YAML_FILES]="CACHED_YAML_FILES"
  STEP_CTX[CACHED_JSON_FILES]="CACHED_JSON_FILES"
  STEP_CTX[CACHED_SHELL_FILES]="CACHED_SHELL_FILES"
  # shellcheck disable=SC2034  # reason: STEP_CTX is consumed inside the step subshells via nameref; shellcheck cannot trace cross-subshell use.
  STEP_CTX[POSITIONAL_ARGS]="POSITIONAL_ARGS"

  rm -rf result result-* # check-suppress:suppression_doc: nix build may leave a 'result' symlink/dir; -rf clears either form

  local _max_jobs _pipeline_start_ms
  _max_jobs="${PARALLEL_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2)}"
  _pipeline_start_ms=$(_step_now_ms)

  local _i _id _skip _skip_id _total _started _n _name
  local -a _pending_indices=() _spawned_steps=()
  _total=${#_STEP_FUNCS[@]}
  _started=0

  for _i in "${!_STEP_FUNCS[@]}"; do
    _id="${_STEP_IDS[$_i]}"
    _n="${_STEP_NUMBERS[$_i]}"
    _name="${_STEP_NAMES[$_i]}"
    _skip=false
    for _skip_id in "${SKIP_STEPS[@]+${SKIP_STEPS[@]}}"; do
      if [ "$_skip_id" = "$_id" ]; then
        _skip=true
        break
      fi
    done
    if $_skip; then
      _run_skipped_step "$_n" "$_name" "$_id"
    else
      _pending_indices+=("$_i")
    fi
  done

  local _pos=0 _batch_end _batch_i _batch_pid _wait_ret _fail_fast_exit=""
  local -a _batch_pids=()
  while [ "$_pos" -lt "${#_pending_indices[@]}" ]; do
    _batch_end=$((_pos + _max_jobs))
    if [ "$_batch_end" -gt "${#_pending_indices[@]}" ]; then
      _batch_end=${#_pending_indices[@]}
    fi
    _batch_pids=()
    while [ "$_pos" -lt "$_batch_end" ]; do
      _i="${_pending_indices[$_pos]}"
      _pos=$((_pos + 1))
      _n="${_STEP_NUMBERS[$_i]}"
      _name="${_STEP_NAMES[$_i]}"
      _started=$((_started + 1))
      _run_step "$_n" "$_name" "${_STEP_FUNCS[$_i]}" "${POSITIONAL_ARGS[@]+${POSITIONAL_ARGS[@]}}" &
      _batch_pids+=($!)
      _spawned_steps+=("$_n")
      printf '%s[%d/%d] step %s %s started%s\n' "${_nuc_c1_dim}" "$_started" "$_total" "$_n" "$_name" "${_nuc_c1_reset}"
    done
    _fail_fast_exit=""
    for _batch_pid in "${_batch_pids[@]}"; do
      _wait_ret=0
      wait "$_batch_pid" || _wait_ret=$?
      if [ "$_wait_ret" -ne 0 ] && [ "$_wait_ret" -ne 2 ] && $FAIL_FAST; then
        _fail_fast_exit="$_wait_ret"
      fi
    done
    if [ -n "$_fail_fast_exit" ]; then
      exit "$_fail_fast_exit"
    fi
  done

  printf '%s' $(($(_step_now_ms) - _pipeline_start_ms)) >"$_wave_tmpdir/pipeline.wall_ms"

  local _elapsed_ms _duration_s
  for _n in "${_spawned_steps[@]}"; do
    _elapsed_ms=$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)
    _duration_s=$(_format_duration_s "$_elapsed_ms")
    printf '%sstep %s finished (%s)%s\n' "${_nuc_c1_dim}" "$_n" "$_duration_s" "${_nuc_c1_reset}"
  done
}

# --- aggregate_results ---
aggregate_results() {
  local _failed_steps=""
  local _total_elapsed=0 _wall_ms=0
  local _n _name _elapsed _exit_code _duration_s

  if [ -f "$_wave_tmpdir/pipeline.wall_ms" ]; then
    _wall_ms=$(cat "$_wave_tmpdir/pipeline.wall_ms" 2>/dev/null || echo 0)
  fi

  printf '\n'
  for _i in "${!_STEP_FUNCS[@]}"; do
    _n="${_STEP_NUMBERS[$_i]}"
    _name="${_STEP_NAMES[$_i]}"
    _exit_code=$(cat "$_wave_tmpdir/step-$_n.exit" 2>/dev/null || echo 1)
    _elapsed=$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)
    _total_elapsed=$((_total_elapsed + _elapsed))
    _duration_s=$(_format_duration_s "$_elapsed")

    # _n is the zero-padded NN- prefix string; 10# forces decimal so %d doesn't parse it as octal.
    if [ "$_exit_code" -eq 0 ]; then
      printf '  %sstep %2d%s  %s✓%s  %s%8s%s  %s\n' "${_nuc_c1_dim}" "$((10#${_n}))" "${_nuc_c1_reset}" "${_nuc_c1_green}" "${_nuc_c1_reset}" "${_nuc_c1_dim}" "$_duration_s" "${_nuc_c1_reset}" "$_name"
    elif [ "$_exit_code" -eq 2 ]; then
      printf '  %sstep %2d%s  %sSKIP%s  %s%8s%s  %s\n' "${_nuc_c1_dim}" "$((10#${_n}))" "${_nuc_c1_reset}" "${_nuc_c1_yellow}" "${_nuc_c1_reset}" "${_nuc_c1_dim}" "$_duration_s" "${_nuc_c1_reset}" "$_name"
    else
      printf '  %sstep %2d%s  %s✗%s  %s%8s%s  %s\n' "${_nuc_c1_dim}" "$((10#${_n}))" "${_nuc_c1_reset}" "${_nuc_c1_red}" "${_nuc_c1_reset}" "${_nuc_c1_dim}" "$_duration_s" "${_nuc_c1_reset}" "$_name"
      _failed_steps="$_failed_steps$((10#${_n})) "
    fi

    if [ -f "$_wave_tmpdir/step-$_n.out" ]; then
      if [ -n "$_nuc_c1_cyan" ]; then
        sed "s/^=== .*$/${_nuc_c1_bold}${_nuc_c1_cyan}&${_nuc_c1_reset}/" "$_wave_tmpdir/step-$_n.out"
      else
        cat "$_wave_tmpdir/step-$_n.out"
      fi
    fi
  done

  printf '\n'
  printf '%s  sum of steps:%s %8s\n' "${_nuc_c1_dim}" "${_nuc_c1_reset}" "$(_format_duration_s "$_total_elapsed")"
  printf '%s  wall clock:  %s %8s\n' "${_nuc_c1_dim}" "${_nuc_c1_reset}" "$(_format_duration_s "$_wall_ms")"
  printf '\n'

  if [ -n "$_failed_steps" ]; then
    error "some checks failed: steps $_failed_steps"
    printf '  Failed steps: %s\n' "$_failed_steps"
    exit 1
  else
    say "${_nuc_c1_green}all checks passed.${_nuc_c1_reset}"
    exit 0
  fi
}

# --- Pre-flight check ---
preflight_check() {
  require_command actionlint
  require_command check-jsonschema
  require_command git # required by deny-list.sh for gitignore filtering; must hard-fail rather than silently pass through
  require_command jq
  require_command nix
  require_command nixf-tidy
  require_command packer
  require_command pinact
  require_command pwsh
  require_command shfmt
  require_command taplo
  require_command treefmt
  require_command yq
  require_command zizmor
}
