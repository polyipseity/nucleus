#!/usr/bin/env bash
# Step runner library for check and test orchestrators.
# Provides step registration, execution, timing, and aggregation.
# Sourced by check-lib.sh and test-lib.sh.
#
# Guard against re-sourcing — step files source independently and
# re-sourcing would wipe step registration arrays, leaving only the last step.
[ -n "${_NUCLEUS_STEP_RUNNER_SOURCED-}" ] && return
_NUCLEUS_STEP_RUNNER_SOURCED=1

# --- Step registration ---
# Indexed arrays: step numbers, step names, step function names.
declare -a _STEP_NUMBERS=()
declare -a _STEP_NAMES=()
declare -a _STEP_FUNCS=()

register_step() {
  local _n="$1" _name="$2" _func="$3"
  _STEP_NUMBERS+=("$_n")
  _STEP_NAMES+=("$_name")
  _STEP_FUNCS+=("$_func")
}

# --- Wave parallelism infrastructure ---
# Each step writes .exit, .time, .name files to _wave_tmpdir.
# Results are aggregated at the end.
_wave_tmpdir=""
_wave_tmpdir_created=false

_wave_init() {
  _wave_tmpdir=$(mktemp -d) || { error "failed to create wave temp directory"; exit 1; }
  _wave_tmpdir_created=true
  trap '_wave_cleanup' EXIT
}

_wave_cleanup() {
  if $_wave_tmpdir_created && [ -n "$_wave_tmpdir" ]; then
    rm -rf -- "$_wave_tmpdir"
  fi
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
  if "$_func" "$_n" "$HAS_ARGS" "$REPO_ROOT" "$_wave_tmpdir" "$@"; then
    _exit_code=0
  else
    _exit_code=$?
  fi >> "$_wave_tmpdir/step-$_n.out" 2>&1

  # 3. Write exit code and timing (framework owns these files)
  printf '%s' "$_exit_code" > "$_wave_tmpdir/step-$_n.exit"
  _elapsed_ms=$(($(date +%s%3N) - _step_start_ms))
  printf '%s' "$_elapsed_ms" > "$_wave_tmpdir/step-$_n.time"

  # 4. Fail-fast check (framework-level concern, not step-level)
  if [ "$_exit_code" -ne 0 ] && $FAIL_FAST; then
    exit "$_exit_code"
  fi
}

# --- Argument parsing ---
parse_args() {
  FORMAT_NIX=false
  ONLINE=false
  SCOPED=false
  FULL=false
  HAS_ARGS=false
  POSITIONAL_ARGS=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --format)
        # shellcheck disable=SC2034 # reason: consumed by check step 01 (code-formatting) via transitive sourcing
        FORMAT_NIX=true
        shift
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
        # shellcheck disable=SC2034 # reason: consumed by check step 18 (online-determinism) via transitive sourcing
        ONLINE=true
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
  readarray -t CACHED_NIX_FILES < <(find . -path ./vendor -prune -false -o -name '*.nix' -print | sort)  # ref: allow-and-deny-lists.instructions.md#B7 — reason: structural invariant
  # shellcheck disable=SC2034 # reason: consumed by step files (13, 15) via transitive sourcing
  readarray -t CACHED_YAML_FILES < <(find . -not -path '*/vendor/*' \( -name '*.yml' -o -name '*.yaml' \) -print | sort)  # ref: allow-and-deny-lists.instructions.md#B7 — reason: structural invariant
  # shellcheck disable=SC2034 # reason: consumed by step files (13) via transitive sourcing
  readarray -t CACHED_JSON_FILES < <(find src -name '*.json' -not -path '*/vendor/*' -not -name '*.schema.json' -print | sort)  # ref: allow-and-deny-lists.instructions.md#A7,#B7 — reason: schema files are meta; vendor is structural invariant
  # shellcheck disable=SC2034 # reason: consumed by step files (17) via transitive sourcing
  readarray -t CACHED_SH_FILES < <(find src/scripts -type f -name '*.sh' -print | sort)
}

# --- run_all_steps ---
# Iterates registered steps, calls _run_step for each, then aggregates.
run_all_steps() {
  _wave_init
  cache_file_lists

  # Remove stale result symlinks before any checks run.
  rm -f result result-*

  local _i
  for _i in "${!_STEP_FUNCS[@]}"; do
    _run_step "${_STEP_NUMBERS[$_i]}" "${_STEP_NAMES[$_i]}" "${_STEP_FUNCS[$_i]}" "${POSITIONAL_ARGS[@]+${POSITIONAL_ARGS[@]}}" &
  done
  wait
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
  require_command packer
  require_command check-jsonschema
}
