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

# --- Step registration ---
# Indexed arrays: step numbers, step names, step function names.
declare -a _STEP_IDS=()
declare -a _STEP_NUMBERS=()
declare -a _STEP_NAMES=()
declare -a _STEP_FUNCS=()

register_step() {
  local _id="$1" _n="$2" _name="$3" _func="$4"

  # Validate id not empty (Spec A).
  if [ -z "$_id" ]; then
    error "Step ID must not be empty"
    exit 1
  fi

  # Validate id contains no digits (Spec A).
  if echo "$_id" | grep -q '[0-9]'; then
    error "Step ID '$_id' contains forbidden digit"
    exit 1
  fi

  # Validate unique id (Spec A).
  local _existing_id
  for _existing_id in ${_STEP_IDS[@]+"${_STEP_IDS[@]}"}; do
    if [ "$_existing_id" = "$_id" ]; then
      error "Duplicate step ID '$_id'"
      exit 1
    fi
  done

  # Validate unique number (Spec A).
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

# --- Wave parallelism infrastructure ---
# Each step writes .exit, .time, .name files to _wave_tmpdir.
# Results are aggregated at the end.
_wave_tmpdir=""
_wave_tmpdir_created=false

_wave_cleanup_stale() {
  # Clean temp dirs from previous runs that were killed before trap cleanup.
  # Uses the nucleus-step-runner prefix to avoid removing unrelated temp dirs.
  # Only removes dirs whose owning PID is no longer alive — concurrent
  # instances of test.sh and check.sh each have their own temp dir.
  local _d _pid
  for _d in "${TMPDIR:-/tmp}/nucleus-step-runner-"*; do
    [ -d "$_d" ] || continue  # check-suppress:suppression_doc: glob may expand to literal pattern when no matches; [ -d ] check filters it
    _pid=$(cat "$_d/pid" 2>/dev/null || true)
    if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
      rm -rf "$_d"
    fi
  done
}

_wave_init() {
  _wave_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nucleus-step-runner-XXXXXX") || { error "failed to create wave temp directory"; exit 1; }
  _wave_tmpdir_created=true
  printf '%s' "$$" > "$_wave_tmpdir/pid"
  trap '_wave_cleanup; exit' INT TERM
  trap '_wave_cleanup' EXIT
}

_wave_cleanup() {
  if $_wave_tmpdir_created && [ -n "$_wave_tmpdir" ]; then
    rm -rf -- "$_wave_tmpdir"
  fi
}

# --- Nix lock ---
# WHY: test steps 1/3/4 and check step 4 invoke nix concurrently from
# parallel background steps; nix's SQLite eval cache then reports "database is
# busy" and flakehub fetches block on "waiting for another Nix process".
# Serializing nix invocations behind one lockfile removes the contention while
# keeping non-nix steps fully parallel. flock(1) is unavailable on macOS, so
# the lock is a mkdir-based mutex with PID-based stale recovery (same pattern
# as _wave_cleanup_stale).
NUCLEUS_NIX_LOCK="${TMPDIR:-/tmp}/nucleus-nix.lock"

nucleus_nix_locked() {
  # Runs "$@" while holding the nix lock; releases unconditionally afterward.
  local _lock_dir="$NUCLEUS_NIX_LOCK"
  local _lock_owner=""
  local _lock_waited=0
  local _lock_ret=0

  # Acquire: mkdir is atomic; loop until we own the lock dir.
  while ! mkdir "$_lock_dir" 2>/dev/null; do
    # Stale-lock recovery: reclaim when the recorded owner PID is dead or
    # missing (crashed holder); BASHPID names the step subshell, not the
    # orchestrator, so a killed step does not wedge the lock.
    _lock_owner="$(cat "$_lock_dir/pid" 2>/dev/null || true)"  # check-suppress:suppression_doc: the pid file may be absent; an empty owner falls through to stale-lock recovery
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
  printf '%s\n' "$BASHPID" > "$_lock_dir/pid"

  # Run the wrapped command, then release unconditionally.
  if "$@"; then
    _lock_ret=0
  else
    _lock_ret=$?
  fi
  rm -rf "$_lock_dir"
  return "$_lock_ret"
}

# Default value if parse_args hasn't been called
HAS_ARGS=${HAS_ARGS:-false}

# --- _run_step wrapper ---
# Owns ALL orchestration I/O: timing, section headers, exit file writing, fail-fast.
# Step functions receive params and write messages to stdout/stderr only.
_run_step() {
  local _n="$1" _name="$2" _func="$3"; shift 3
  local _step_start_ms _elapsed_ms _exit_code

  _step_start_ms=$(date +%s%3N)

  # 1. Write section header + step name
  printf '\n=== [%s] %s ===\n' "$_n" "$_name" > "$_wave_tmpdir/step-$_n.out"
  printf '%s' "$_name" > "$_wave_tmpdir/step-$_n.name"

  # 2. Run step function, capture ALL output (stdout+stderr)
  if "$_func" "$HAS_ARGS" "$REPO_ROOT" "$@"; then
    _exit_code=0
  else
    _exit_code=$?
  fi >> "$_wave_tmpdir/step-$_n.out" 2>&1

  # 3. Write exit code and timing (framework owns these files)
  printf '%s' "$_exit_code" > "$_wave_tmpdir/step-$_n.exit"
  _elapsed_ms=$(($(date +%s%3N) - _step_start_ms))
  printf '%s' "$_elapsed_ms" > "$_wave_tmpdir/step-$_n.time"

  # 4. Fail-fast check (framework-level concern, not step-level)
  # Exit code 2 = skipped step; never a failure, so never fail-fast on it.
  if [ "$_exit_code" -ne 0 ] && [ "$_exit_code" -ne 2 ] && $FAIL_FAST; then
    exit "$_exit_code"
  fi
}

# --- _run_skipped_step helper ---
# Writes step files with a SKIPPED marker instead of executing the step function.
_run_skipped_step() {
  local _n="$1" _name="$2" _id="$3"
  local _step_start_ms _elapsed_ms

  _step_start_ms=$(date +%s%3N)

  printf '\n=== [%s] %s === SKIPPED (--skip-steps: %s)\n' "$_n" "$_name" "$_id" > "$_wave_tmpdir/step-$_n.out"
  printf '%s' "$_name" > "$_wave_tmpdir/step-$_n.name"
  # Exit code 2 = skipped step (rendered as SKIP, not a failure).
  printf '%s' "2" > "$_wave_tmpdir/step-$_n.exit"
  _elapsed_ms=$(($(date +%s%3N) - _step_start_ms))
  printf '%s' "$_elapsed_ms" > "$_wave_tmpdir/step-$_n.time"
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
      -h|--help)
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
        # shellcheck disable=SC2034 # reason: consumed by check step 14 (online-determinism) via transitive sourcing
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

  # Validate mutual exclusivity: --scoped and --full cannot be combined.
  if "$SCOPED" && "$FULL"; then
    error "cannot specify both --scoped and --full"
    usage >&2
    exit 1
  fi

  # Determine HAS_ARGS based on paths and mode flags.
  [ "$#" -gt 0 ] && HAS_ARGS=true
  if $SCOPED; then
    HAS_ARGS=true
  fi
  if $FULL; then
    HAS_ARGS=false
  fi

  POSITIONAL_ARGS=("$@")

  # When paths are provided, group them by extension.
  SH_FILES=()
  PS1_FILES=()
  PKR_FILES=()
  NIX_FILES=()
  if $HAS_ARGS; then
    for _f in "$@"; do
      case "$_f" in
        *.sh)      SH_FILES+=("$_f") ;;
        *.ps1)     PS1_FILES+=("$_f") ;;
        *.pkr.hcl) PKR_FILES+=("$_f") ;;
        *.nix)     NIX_FILES+=("$_f") ;;
      esac
    done
  fi
}

# --- File caching ---
# Populates CACHED_NIX_FILES, CACHED_YAML_FILES, CACHED_JSON_FILES, CACHED_SH_FILES.
# Called only in full mode before steps fire.
cache_file_lists() {
  # shellcheck disable=SC2034 # reason: consumed by step files (05, 13, 15, 17) via transitive sourcing
  readarray -t CACHED_NIX_FILES < <(
    find . -path ./vendor -prune -false -o -name '*.nix' -print \
    | filter_gitignored \
    | sort
  )  # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step files (13, 15) via transitive sourcing
  readarray -t CACHED_YAML_FILES < <(
    find . -not -path '*/vendor/*' \( -name '*.yml' -o -name '*.yaml' \) -print \
    | filter_gitignored \
    | sort
  )  # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step files (13) via transitive sourcing
  readarray -t CACHED_JSON_FILES < <(
    find src -name '*.json' -not -path '*/vendor/*' -not -name '*.schema.json' -print \
    | filter_gitignored \
    | sort
  )  # ref: allow-and-deny-lists.instructions.md#A7,#B7 -- schema files are meta; vendor is structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step files (17) via transitive sourcing
  readarray -t CACHED_SH_FILES < <(
    find src/scripts -type f -name '*.sh' -print \
    | filter_gitignored \
    | sort
  )
}

# --- run_all_steps ---
# Iterates registered steps, calls _run_step for each, then aggregates.
run_all_steps() {
  _wave_cleanup_stale
  _wave_init
  cache_file_lists

  # Remove stale result symlinks before any checks run.
  rm -f result result-*

  local _i _id _skip _skip_id _total _started _n _name _spawned_steps=()
  _total=${#_STEP_FUNCS[@]}
  _started=0
  for _i in "${!_STEP_FUNCS[@]}"; do
    _id="${_STEP_IDS[$_i]}"
    _n="${_STEP_NUMBERS[$_i]}"
    _name="${_STEP_NAMES[$_i]}"
    # Check skip list. Use safe expansion in case SKIP_STEPS is unset.
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
      _started=$((_started + 1))
      _run_step "$_n" "$_name" "${_STEP_FUNCS[$_i]}" "${POSITIONAL_ARGS[@]+${POSITIONAL_ARGS[@]}}" &
      _spawned_steps+=("$_n")
      # Live progress: announce each step as it launches (unbuffered stdout).
      printf '[%d/%d] step %s %s started\n' "$_started" "$_total" "$_n" "$_name"
    fi
  done
  wait

  # Live progress: report elapsed time per launched step (mm:ss).
  local _elapsed_ms _elapsed_s
  for _n in "${_spawned_steps[@]}"; do
    _elapsed_ms=$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)
    _elapsed_s=$((_elapsed_ms / 1000))
    printf 'step %s finished (%02d:%02d)\n' "$_n" "$((_elapsed_s / 60))" "$((_elapsed_s % 60))"
  done
}

# --- aggregate_results ---
# Combined status table from .exit/.time/.name files.
aggregate_results() {
  local _total_steps=${#_STEP_FUNCS[@]}
  local _failed_steps=""
  local _total_elapsed=0
  local _n _name _elapsed _exit_code

  printf '\n'
  for _i in "${!_STEP_FUNCS[@]}"; do
    _n="${_STEP_NUMBERS[$_i]}"
    _name="${_STEP_NAMES[$_i]}"
    _exit_code=$(cat "$_wave_tmpdir/step-$_n.exit" 2>/dev/null || echo 1)
    _elapsed=$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)
    _total_elapsed=$((_total_elapsed + _elapsed))

    if [ "$_exit_code" -eq 0 ]; then
      printf '  step %2d  ✓  %5d ms  %s\n' "$_n" "$_elapsed" "$_name"
    elif [ "$_exit_code" -eq 2 ]; then
      # Exit code 2 = skipped step; rendered as SKIP, never a failure.
      printf '  step %2d  SKIP %5d ms  %s\n' "$_n" "$_elapsed" "$_name"
    else
      printf '  step %2d  ✗  %5d ms  %s\n' "$_n" "$_elapsed" "$_name"
      _failed_steps="$_failed_steps$_n "
    fi

    # Replay step output
    if [ -f "$_wave_tmpdir/step-$_n.out" ]; then
      cat "$_wave_tmpdir/step-$_n.out"
    fi
  done

  printf '\n'
  printf '  total:   %5d ms\n' "$_total_elapsed"
  printf '\n'

  if [ -n "$_failed_steps" ]; then
    error "some checks failed: steps $_failed_steps"
    printf '  Failed steps: %s\n' "$_failed_steps"
    exit 1
  else
    say "all checks passed."
    exit 0
  fi
}

# --- Pre-flight check ---
preflight_check() {
  require_command pwsh
  require_command treefmt
  require_command yq
  require_command jq
  require_command nixf-tidy
  require_command nix
  require_command git  # required by deny-list.sh for gitignore filtering; must hard-fail rather than silently pass through
  require_command packer
  require_command check-jsonschema
}
