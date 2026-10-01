#!/usr/bin/env bash
# Step runner library for check and test orchestrators. Sourced by check-lib.sh
# and test-lib.sh.
# Re-sourcing would wipe the step registration arrays, leaving only the last step.
[ -n "${_NUCLEUS_STEP_RUNNER_SOURCED-}" ] && return
_NUCLEUS_STEP_RUNNER_SOURCED=1

# shellcheck source=./deny-list.sh
# WHY self-derived dir: test harnesses source this file from their own
# directories, so ambient SCRIPT_DIR resolves to the wrong path.
_NUCLEUS_STEP_RUNNER_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$_NUCLEUS_STEP_RUNNER_DIR/deny-list.sh"

# shellcheck source=./lib.sh
. "$_NUCLEUS_STEP_RUNNER_DIR/lib.sh"

declare -a _STEP_IDS=()
declare -a _STEP_NUMBERS=()
declare -a _STEP_NAMES=()
declare -a _STEP_FUNCS=()
declare -a _STEP_PLATFORMS=()
declare -a _STEP_MODES=()
declare -a _STEP_REQUIRES=()
# Populated at dispatch, rendered by aggregate_results as '–'.
declare -A _NOT_RUN_STATES=()

register_step() {
  local _id _n _name _func _base _platform=any _mode=any _requires=none

  case "$#" in
  3)
    _id="$1" _name="$2" _func="$3"
    ;;
  4)
    _id="$1" _n="$2" _name="$3" _func="$4"
    ;;
  6)
    _id="$1" _name="$2" _func="$3" _platform="$4" _mode="$5" _requires="$6"
    ;;
  *)
    printf '%s\n' "register_step: expected 3, 4 or 6 arguments (id [number] name func [platform mode requires]), got $#: $*" >&2
    return 1
    ;;
  esac

  case "$_platform" in
  any | posix | windows) ;;
  *)
    error "register_step: unknown platform token '$_platform' (expected posix|windows|any)"
    exit 1
    ;;
  esac
  case "$_mode" in
  any | full | scoped) ;;
  *)
    error "register_step: unknown mode token '$_mode' (expected any|full|scoped)"
    exit 1
    ;;
  esac
  case "$_requires" in
  none | nix | network | sops-machine-key | deployed-host) ;;
  *)
    error "register_step: unknown requires token '$_requires' (expected none|nix|network|sops-machine-key|deployed-host)"
    exit 1
    ;;
  esac

  # 3- and 6-arg forms carry no number; derive it from the caller file's NN- prefix.
  if [ "$#" -ne 4 ]; then
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
  fi

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
  _STEP_PLATFORMS+=("$_platform")
  _STEP_MODES+=("$_mode")
  _STEP_REQUIRES+=("$_requires")
}

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

# ref: tooling-and-validation.instructions.md
# Point <nixpkgs> at the flake-locked input so no step resolves it through this
# machine's channel or registry. The first call pins it; later calls reuse it.
nucleus_pin_nixpkgs() {
  local _repo_root="$1"
  local _pin_out

  if [ -z "${NUCLEUS_PINNED_NIXPKGS:-}" ]; then
    # WHY: a failed or empty build must fail the caller's step, never pin "$empty/nixpkgs".
    if ! _pin_out="$(nix build --no-link --print-out-paths "$_repo_root/src#flakeInputs")"; then
      error "failed to build the flakeInputs derivation from $_repo_root/src — cannot pin <nixpkgs>"
      return 1
    fi
    if [ ! -d "$_pin_out/nixpkgs" ]; then
      error "flakeInputs output $_pin_out has no nixpkgs/ directory — cannot pin <nixpkgs>"
      return 1
    fi
    NUCLEUS_PINNED_NIXPKGS="${_pin_out%/}/nixpkgs"
  fi
  export NUCLEUS_PINNED_NIXPKGS
  export NIX_PATH="nixpkgs=$NUCLEUS_PINNED_NIXPKGS"
}

# WHY bound here: parse_args may be uncalled (unit tests source this lib directly)
# and run_all_steps reads all of them eagerly under `set -u`.
HAS_ARGS=${HAS_ARGS:-false}
FAIL_FAST=${FAIL_FAST:-false}
ONLINE=${ONLINE:-false}
VERBOSE_IDS=()
ONLY_STEPS=()

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

_run_step() {
  local _n="$1" _name="$2" _func="$3" _id="$4"
  shift 4
  local _step_start_ms _elapsed_ms _exit_code _fifo

  _step_start_ms=$(_step_now_ms)

  printf '\n=== [%s] %s ===\n' "$_n" "$_name" >"$_wave_tmpdir/step-$_n.out"
  printf '%s' "$_name" >"$_wave_tmpdir/step-$_n.name"

  local _is_verbose=false
  if [ "${#VERBOSE_IDS[@]}" -gt 0 ]; then
    for _vid in "${VERBOSE_IDS[@]}"; do
      if [ "$_vid" = "*" ] || [ "$_vid" = "$_id" ]; then
        _is_verbose=true
        break
      fi
    done
  fi

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

  if $_is_verbose; then
    tee -a "$_wave_tmpdir/step-$_n.out" <"$_fifo" | while IFS= read -r _line || [ -n "$_line" ]; do
      printf '%s[step %2d]%s %s\n' "${_nuc_c2_dim}" "$((10#${_n}))" "${_nuc_c2_reset}" "$_line" >&2
    done
  else
    cat <"$_fifo" >>"$_wave_tmpdir/step-$_n.out" &
  fi

  _exit_code=0
  wait "$_func_pid" || _exit_code=$?
  rm -f "$_fifo"

  printf '%s' "$_exit_code" >"$_wave_tmpdir/step-$_n.exit"
  _elapsed_ms=$(($(_step_now_ms) - _step_start_ms))
  printf '%s' "$_elapsed_ms" >"$_wave_tmpdir/step-$_n.time"

  if [ "$_exit_code" -ne 0 ] && $FAIL_FAST; then
    exit "$_exit_code"
  fi
}

# ref: step-runner.instructions.md -- declared applicability replaces step-level skipping.
# The runner decides whether a step runs; a step file never probes its own
# prerequisites or reports a skip sentinel.
_step_platform_applicable() {
  case "$1" in
  any | posix) return 0 ;;
  windows) return 1 ;;
  esac
}

# HAS_ARGS is the runner's scoped/full determination (positional args or --scoped).
_step_mode_applicable() {
  case "$1" in
  any) return 0 ;;
  scoped) [ "$HAS_ARGS" = true ] ;;
  full) [ "$HAS_ARGS" = false ] ;;
  esac
}

_step_prerequisite_met() {
  case "$1" in
  none) return 0 ;;
  nix) command -v nix >/dev/null 2>&1 ;;
  network) [ "$ONLINE" = true ] ;;
  sops-machine-key) [ -f "$(nucleus_machine_age_key_path)" ] ;;
  deployed-host) [ -f "$(derive_nucleus_user_root)/method1-symlink-manifest.txt" ] ;;
  esac
}

# Prints the state of a step that will not run, or nothing when it runs.
# Selection is checked first: an unselected step reports not-selected.
_step_run_state() {
  local _id="$1" _platform="$2" _mode="$3" _requires="$4" _sel
  if [ "${#ONLY_STEPS[@]}" -gt 0 ]; then
    for _sel in "${ONLY_STEPS[@]}"; do
      [ "$_sel" = "$_id" ] && return 0
    done
    printf '%s\n' "not-selected"
    return 0
  fi
  if ! _step_platform_applicable "$_platform"; then
    printf 'not applicable (platform: %s)\n' "$_platform"
    return 0
  fi
  if ! _step_mode_applicable "$_mode"; then
    printf 'not applicable (mode: %s)\n' "$_mode"
    return 0
  fi
  if ! _step_prerequisite_met "$_requires"; then
    printf 'not applicable (requires: %s)\n' "$_requires"
    return 0
  fi
  return 0
}

# A typo in ONLY_STEPS would otherwise narrow the run to nothing and report success.
validate_only_steps() {
  local _only _kid _known _known_list
  _known_list=""
  for _kid in "${_STEP_IDS[@]}"; do
    [ -n "$_known_list" ] && _known_list="$_known_list, "
    _known_list="$_known_list$_kid"
  done
  for _only in "${ONLY_STEPS[@]}"; do
    _known=false
    for _kid in "${_STEP_IDS[@]}"; do
      [ "$_kid" = "$_only" ] && _known=true && break
    done
    if ! $_known; then
      error "unknown step id '$_only' in --only-steps (known: $_known_list)"
      usage >&2
      exit 1
    fi
  done
}

parse_args() {
  ONLINE=false
  SCOPED=false
  FULL=false
  HAS_ARGS=false
  POSITIONAL_ARGS=()
  ONLY_STEPS=()

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
      # shellcheck disable=SC2034 # reason: consumed by this file's own network prerequisite branch (_step_mode_applicable); no check step declares requires network today, so nothing else reads it via transitive sourcing
      ONLINE=true
      shift
      ;;
    --verbose)
      VERBOSE_IDS=("*")
      shift
      ;;
    --verbose=*)
      VERBOSE_IDS=()
      local _vval="${1#--verbose=}"
      if [ -n "$_vval" ]; then
        local _old_ifs="$IFS"
        IFS=','
        for _part in $_vval; do
          _part="${_part## }"
          _part="${_part%% }"
          if [ -n "$_part" ]; then
            VERBOSE_IDS+=("$_part")
          fi
        done
        IFS="$_old_ifs"
      fi
      shift
      ;;
    --no-verbose)
      VERBOSE_IDS=()
      shift
      ;;
    --only-steps=*)
      ONLY_STEPS=()
      local _val="${1#--only-steps=}"
      if [ -n "$_val" ]; then
        local _old_ifs="$IFS"
        IFS=','
        for _part in $_val; do
          _part="${_part## }"
          _part="${_part%% }"
          if [ -n "$_part" ]; then
            local _already=false
            for _existing in "${ONLY_STEPS[@]}"; do
              [ "$_existing" = "$_part" ] && _already=true && break
            done
            $_already || ONLY_STEPS+=("$_part")
          fi
        done
        IFS="$_old_ifs"
      fi
      validate_only_steps
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

cache_file_lists() {
  # shellcheck disable=SC2034 # reason: consumed by step files 03 and 11 via transitive sourcing
  readarray -t CACHED_NIX_FILES < <(
    find . -path ./vendor -prune -false -o -name '*.nix' -print |
      filter_gitignored |
      sort
  ) # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  # shellcheck disable=SC2034 # reason: consumed by step file 07 via transitive sourcing
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

run_all_steps() {
  _wave_cleanup_stale
  _wave_init
  cache_file_lists

  # Every step receives this object as its first argument, so no step reads
  # enclosing globals and the contract matches the PowerShell runner.
  local -A STEP_CTX=()
  STEP_CTX[HAS_ARGS]="$HAS_ARGS"
  STEP_CTX[REPO_ROOT]="$REPO_ROOT"
  STEP_CTX[_wave_tmpdir]="$_wave_tmpdir"
  STEP_CTX[FAIL_FAST]="$FAIL_FAST"
  STEP_CTX[VERBOSE_IDS]="VERBOSE_IDS"
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

  local _i _id _state _total _started _n _name
  local -a _pending_indices=() _spawned_steps=()
  _NOT_RUN_STATES=()
  _started=0

  for _i in "${!_STEP_FUNCS[@]}"; do
    _id="${_STEP_IDS[$_i]}"
    _n="${_STEP_NUMBERS[$_i]}"
    _name="${_STEP_NAMES[$_i]}"
    _state="$(_step_run_state "$_id" "${_STEP_PLATFORMS[$_i]}" "${_STEP_MODES[$_i]}" "${_STEP_REQUIRES[$_i]}")"
    if [ -n "$_state" ]; then
      _NOT_RUN_STATES[$_n]="$_state"
      printf '\n%s=== [%s] %s === %s%s\n' "${_nuc_c1_bold}${_nuc_c1_cyan}" "$_n" "$_name" "$_state" "${_nuc_c1_reset}"
    else
      _pending_indices+=("$_i")
    fi
  done

  _total=${#_pending_indices[@]}

  local _pos=0 _batch_end _batch_i _wait_ret _fail_fast=false
  local -a _batch_pids=() _batch_indices=() _fail_fast_indices=()
  while [ "$_pos" -lt "${#_pending_indices[@]}" ]; do
    _batch_end=$((_pos + _max_jobs))
    if [ "$_batch_end" -gt "${#_pending_indices[@]}" ]; then
      _batch_end=${#_pending_indices[@]}
    fi
    _batch_pids=()
    _batch_indices=()
    while [ "$_pos" -lt "$_batch_end" ]; do
      _i="${_pending_indices[$_pos]}"
      _pos=$((_pos + 1))
      _n="${_STEP_NUMBERS[$_i]}"
      _name="${_STEP_NAMES[$_i]}"
      _id="${_STEP_IDS[$_i]}"
      _started=$((_started + 1))
      _run_step "$_n" "$_name" "${_STEP_FUNCS[$_i]}" "$_id" "${POSITIONAL_ARGS[@]+${POSITIONAL_ARGS[@]}}" &
      _batch_pids+=($!)
      _batch_indices+=("$_i")
      _spawned_steps+=("$_n")
      printf '%s[%d/%d] step %s %s started%s\n' "${_nuc_c1_dim}" "$_started" "$_total" "$_n" "$_name" "${_nuc_c1_reset}"
    done
    _fail_fast=false
    for _batch_i in "${!_batch_pids[@]}"; do
      _wait_ret=0
      wait "${_batch_pids[$_batch_i]}" || _wait_ret=$?
      if [ "$_wait_ret" -ne 0 ] && $FAIL_FAST; then
        _fail_fast=true
        _fail_fast_indices+=("${_batch_indices[$_batch_i]}")
      fi
    done
    if $_fail_fast; then
      _report_fail_fast "${_fail_fast_indices[@]}"
      exit 1
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

# One step's summary line, shared by the fail-fast abort and aggregate_results so
# a failing step renders identically either way.
_print_step_line() {
  local _i="$1" _glyph="$2" _color="$3"
  local _n="${_STEP_NUMBERS[$_i]}" _name="${_STEP_NAMES[$_i]}"
  local _elapsed_ms _duration_s
  _elapsed_ms=$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)
  _duration_s=$(_format_duration_s "$_elapsed_ms")
  printf '  %sstep %2d%s  %s%s%s  %s%8s%s  %s\n' "${_nuc_c1_dim}" "$((10#${_n}))" "${_nuc_c1_reset}" "$_color" "$_glyph" "${_nuc_c1_reset}" "${_nuc_c1_dim}" "$_duration_s" "${_nuc_c1_reset}" "$_name"
}

# Replays a step's captured stdout/stderr, highlighting the header lines.
_replay_step_output() {
  local _n="${_STEP_NUMBERS[$1]}"
  [ -f "$_wave_tmpdir/step-$_n.out" ] || return 0
  if [ -n "$_nuc_c1_cyan" ]; then
    sed "s/^=== .*$/${_nuc_c1_bold}${_nuc_c1_cyan}&${_nuc_c1_reset}/" "$_wave_tmpdir/step-$_n.out"
  else
    cat "$_wave_tmpdir/step-$_n.out"
  fi
}

# True when a step's output carries the no-scope convention. A filtering step with
# an empty scope exits 0, so without this its only news (why it checked nothing)
# is dropped and a ✓ sits beside a step that did no work. no-scope-message-tests.sh
# enforces the convention over every step.
_step_reports_no_scope() {
  local _out="$_wave_tmpdir/step-${_STEP_NUMBERS[$1]}.out"
  [ -f "$_out" ] || return 1
  # WHY anchor at the label boundary: steps emit through say/Write-Message, which
  # prefix `<label>: `, so a real line reads `05-lockfile-validation: 0 lockfile
  # files in scope` and never starts with `0`. A `^0 ` anchor matched a bare echo
  # in the test and nothing in production.
  grep -qE '(^|: )0 .+ in scope' "$_out"
}

# A fail-fast abort exits before aggregate_results, the only other place step
# output is replayed, and the pre-push hook cannot pass --no-fail-fast.
_report_fail_fast() {
  local _i _failed=""
  printf '\n'
  for _i in "$@"; do
    _print_step_line "$_i" "✗" "${_nuc_c1_red}"
    _replay_step_output "$_i"
    _failed="$_failed$((10#${_STEP_NUMBERS[$_i]})) "
  done
  printf '\n'
  error "some checks failed: steps $_failed"
  printf '  Failed steps: %s\n' "$_failed"
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
    if [ -n "${_NOT_RUN_STATES[$_n]:-}" ]; then
      # '–' for state and duration.
      printf '  %sstep %2d%s  %s–%s  %s%8s%s  %s\n' "${_nuc_c1_dim}" "$((10#${_n}))" "${_nuc_c1_reset}" "${_nuc_c1_yellow}" "${_nuc_c1_reset}" "${_nuc_c1_dim}" "–" "${_nuc_c1_reset}" "$_name"
      continue
    fi

    _exit_code=$(cat "$_wave_tmpdir/step-$_n.exit" 2>/dev/null || echo 1)
    _elapsed=$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)
    _total_elapsed=$((_total_elapsed + _elapsed))
    _duration_s=$(_format_duration_s "$_elapsed")

    # 10# forces decimal so %d doesn't read the zero-padded NN- prefix as octal.
    if [ "$_exit_code" -eq 0 ]; then
      _print_step_line "$_i" "✓" "${_nuc_c1_green}"
    else
      _print_step_line "$_i" "✗" "${_nuc_c1_red}"
      _failed_steps="$_failed_steps$((10#${_n})) "
    fi

    local _step_id="${_STEP_IDS[$_i]}"
    local _should_replay=false
    if [ "${#VERBOSE_IDS[@]}" -gt 0 ]; then
      for _vid in "${VERBOSE_IDS[@]}"; do
        if [ "$_vid" = "*" ] || [ "$_vid" = "$_step_id" ]; then
          _should_replay=true
          break
        fi
      done
    fi
    # failed steps replay regardless of verbose mode
    if [ "$_exit_code" -ne 0 ]; then
      _should_replay=true
    fi
    # WHY: also replay a passing step with nothing in scope, so the run does not
    # report the same ✓ for "checked and found nothing" and "never ran".
    if _step_reports_no_scope "$_i"; then
      _should_replay=true
    fi
    if $_should_replay; then
      _replay_step_output "$_i"
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
  require_command yamllint
  require_command yq
  require_command zizmor
}
