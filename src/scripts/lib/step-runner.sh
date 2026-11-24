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
# External tools a step invokes. preflight_check asserts only the tools of steps
# that will actually run, so a path-scoped or --only-steps run never demands a
# tool its selected steps do not use.
declare -a _STEP_TOOLS=()
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
  _STEP_TOOLS+=("")
}

# register_step_tools <id> <space-separated tools>
# Declares the external commands a step invokes. preflight_check requires exactly
# these, so a tool missing from this list is caught when its step runs and a tool
# belonging to an unselected step is never demanded.
register_step_tools() {
  local _id="$1" _tools="$2" _i
  for _i in "${!_STEP_IDS[@]}"; do
    if [ "${_STEP_IDS[$_i]}" = "$_id" ]; then
      _STEP_TOOLS[_i]="$_tools"
      return 0
    fi
  done
  error "register_step_tools: unknown step id '$_id'"
  exit 1
}

_wave_tmpdir=""
_wave_tmpdir_created=false
_runner_steps_started=0
_runner_abort_rc=0
_runner_abort_cmd=""
_runner_abort_func=""
_runner_abort_reported=false

_runner_abort_err_trap() {
  _runner_abort_rc=$?
  _runner_abort_cmd=$BASH_COMMAND
  _runner_abort_func="${FUNCNAME[1]:-}"
}

_runner_abort_exit_trap() {
  local _rc=$?
  _wave_cleanup
  if [ "$_runner_abort_reported" = false ] && [ "$_runner_steps_started" -eq 0 ] && [ "$_rc" -ne 0 ] && [ "${_NUCLEUS_ERROR_REPORTED:-false}" != true ]; then
    _runner_abort_reported=true
    printf 'error: runner aborted before any step started (exit %s)' "$_rc" >&2
    # WHY: ERR only fires on command failures, not explicit exits. A stale
    # command from an earlier ERR would misattribute the abort.
    if [ -n "$_runner_abort_cmd" ] && [ "${_runner_abort_rc:-}" = "$_rc" ]; then
      printf ': %s' "$_runner_abort_cmd" >&2
      if [ -n "$_runner_abort_func" ] && [ "$_runner_abort_func" != "main" ]; then
        printf ' (in %s)' "$_runner_abort_func" >&2
      fi
    fi
    printf '
' >&2
  fi
}

_wave_cleanup_stale() {
  local _d _pid
  for _d in "${TMPDIR:-/tmp}/nucleus-step-runner-"*; do
    [ -d "$_d" ] || continue                  # check-suppress:suppression_doc: glob may expand to literal pattern when no matches; [ -d ] check filters it
    _pid=$(cat "$_d/pid" 2>/dev/null || true) # check-suppress:suppression_doc: pid file may not exist yet; empty pid handled below
    if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
      if ! rm -rf -- "$_d"; then
        error "failed to remove stale wave temp dir: $_d" || continue
      fi
    fi
  done
}

_wave_init() {
  _wave_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nucleus-step-runner-XXXXXX") || {
    error "failed to create wave temp directory"
    exit 1
  }
  _wave_tmpdir_created=true
  _runner_steps_started=0
  _runner_abort_rc=0
  _runner_abort_cmd=""
  _runner_abort_func=""
  _runner_abort_reported=false
  _NUCLEUS_ERROR_REPORTED=false
  printf '%s' "$$" >"$_wave_tmpdir/pid"
  set -E
  trap '_runner_abort_err_trap' ERR
  trap '_wave_cleanup; exit' INT TERM
  trap '_runner_abort_exit_trap' EXIT
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
      python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$_lock_dir"
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
  python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$_lock_dir"
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
      error "hint: if nixpkgs fetch/GC/403 blocks resolution, pre-pin and rerun with NUCLEUS_PINNED_NIXPKGS=\"\$NIX_PATH_PIN\" <script> (no NIX_PATH=, no nix_path prefix)"
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
_step_timeout_default_seconds=600
_step_timeout_seconds="$_step_timeout_default_seconds"

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
  local _step_start_ms _elapsed_ms _exit_code _fifo _reader_pid

  _step_start_ms=$(_step_now_ms)

  printf '\n=== [%s] %s ===\n' "$_n" "$_name" >"$_wave_tmpdir/step-$_n.out"
  printf '%s' "$_name" >"$_wave_tmpdir/step-$_n.name"
  printf '%s' "$_step_start_ms" >"$_wave_tmpdir/step-$_n.start"

  local _is_verbose=false
  if [ "${#VERBOSE_IDS[@]}" -gt 0 ]; then
    for _vid in "${VERBOSE_IDS[@]}"; do
      if [ "$_vid" = "*" ] || [ "$_vid" = "$_id" ]; then
        _is_verbose=true
        break
      fi
    done
  fi

  # WHY inside the wave directory: a step FIFO created outside it has to be
  # removed on its own, and a deletion transport that cannot move a FIFO returns
  # non-zero, which under `set -e` killed the step before it recorded its exit
  # status. _wave_cleanup removes the wave directory wholesale, and removing a
  # directory works on every transport.
  _fifo="$_wave_tmpdir/step-$_n.fifo"
  mkfifo "$_fifo"
  # WHY: only a bounded run needs its own process group, because only then does
  # the runner kill the step's children. Without job control the group kill is a
  # no-op and a stalled nix child would outlive the step it belongs to.
  if [ "$_step_timeout_seconds" -gt 0 ]; then
    set -m
  fi
  (
    if "$_func" "STEP_CTX" "$@"; then
      exit 0
    else
      exit $?
    fi
  ) >"$_fifo" 2>&1 &
  local _func_pid=$!
  if [ "$_step_timeout_seconds" -gt 0 ]; then
    set +m
  fi

  if $_is_verbose; then
    tee -a "$_wave_tmpdir/step-$_n.out" <"$_fifo" | while IFS= read -r _line || [ -n "$_line" ]; do
      printf '%s[step %2d]%s %s\n' "${_nuc_c2_dim}" "$((10#${_n}))" "${_nuc_c2_reset}" "$_line" >&2
    done &
    _reader_pid=$!
  else
    cat <"$_fifo" >>"$_wave_tmpdir/step-$_n.out" &
    _reader_pid=$!
  fi

  _exit_code=0
  if [ "$_step_timeout_seconds" -gt 0 ]; then
    # WHY wall clock rather than a tick count: each tick also does read -t,
    # kill -0 and date, so a counted 0.25 s tick costs more than 0.25 s and the
    # drift lands on the deadline: a 2 s bound reported 2.290 s idle and 9 s
    # under the runner's own parallel fan-out. step-runner.ps1 already computes
    # a wall-clock deadline from the stopwatch, so this is the parity fix.
    local _bound_ms=$((_step_timeout_seconds * 1000)) _step_now
    while kill -0 "$_func_pid" 2>/dev/null; do
      _step_now=$(_step_now_ms)
      if [ $((_step_now - _step_start_ms)) -ge "$_bound_ms" ]; then
        printf 'step %s exceeded NUCLEUS_STEP_TIMEOUT=%ss\n' "$_n" "$_step_timeout_seconds" >>"$_wave_tmpdir/step-$_n.out"
        printf 'step %s exceeded NUCLEUS_STEP_TIMEOUT=%ss\n' "$_n" "$_step_timeout_seconds"
        # check-suppress:suppression_doc: the process already outlived its bound; a failing signal must not change the 124 answer
        kill -TERM -- "-$_func_pid" "$_func_pid" 2>/dev/null || true
        sleep 0.2
        # check-suppress:suppression_doc: same as above, and the group may not exist without job control
        kill -KILL -- "-$_func_pid" "$_func_pid" 2>/dev/null || true
        # check-suppress:suppression_doc: same as above
        wait "$_func_pid" 2>/dev/null || true
        _exit_code=124
        break
      fi
      sleep 0.25
    done
    if [ "$_exit_code" -eq 0 ]; then
      wait "$_func_pid" || _exit_code=$?
    fi
  else
    wait "$_func_pid" || _exit_code=$?
  fi

  # check-suppress:suppression_doc: reader exit follows FIFO EOF; its status must not replace the step's
  wait "$_reader_pid" 2>/dev/null || true
  # check-suppress:suppression_doc: tee in the verbose pipeline is not the waited pid; reap it before writing exit/time
  wait 2>/dev/null || true

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

  # check-suppress:suppression_doc: notice helper is optional when the freshness lib is not sourced by the caller
  command -v warn_if_bundle_predates_tree >/dev/null 2>&1 && warn_if_bundle_predates_tree
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

  # check-suppress:suppression_doc: notice helper is optional when the freshness lib is not sourced by the caller
  command -v warn_if_bundle_predates_tree >/dev/null 2>&1 && warn_if_bundle_predates_tree

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
  if [ "$_max_jobs" -lt 1 ]; then
    _max_jobs=1
  fi
  _pipeline_start_ms=$(_step_now_ms)

  _step_timeout_seconds="${NUCLEUS_STEP_TIMEOUT:-$_step_timeout_default_seconds}"
  case "$_step_timeout_seconds" in
  '' | *[!0-9]*)
    error "NUCLEUS_STEP_TIMEOUT must be whole seconds (got '$_step_timeout_seconds')"
    exit 2
    ;;
  esac

  local _i _id _state _total _started _n _name
  local -a _pending_indices=()
  _NOT_RUN_STATES=()
  _started=0
  _runner_steps_started=0

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

  # Work queue: keep up to _max_jobs wrappers running and launch the next
  # pending step the moment a slot frees, instead of waiting out a batch.
  # WHY poll loop: wait -n blocks, so a heartbeat and Task 3's timeout would
  # never fire while a step was running. The 0.25 s tick wakes the loop for both.
  local _pos=0 _wait_ret _launch_pos _k _stop_launching=false
  local _reaped_any=false _tick_seconds=0.25 _progress_seconds _ticks_per_progress _ticks=0
  local -a _run_pids=() _run_positions=() _launched_positions=() _fail_fast_indices=()
  local -A _failed_positions=()

  _progress_seconds="${NUCLEUS_STEP_PROGRESS_INTERVAL:-15}"
  case "$_progress_seconds" in
  '' | *[!0-9]*)
    error "NUCLEUS_STEP_PROGRESS_INTERVAL must be whole seconds (got '$_progress_seconds')"
    exit 2
    ;;
  esac
  if [ "$_progress_seconds" -gt 0 ]; then
    _ticks_per_progress=$((_progress_seconds * 4))
  else
    _ticks_per_progress=0
  fi

  while :; do
    while ! $_stop_launching && [ "${#_run_pids[@]}" -lt "$_max_jobs" ] && [ "$_pos" -lt "${#_pending_indices[@]}" ]; do
      _launch_pos=$_pos
      _i="${_pending_indices[$_launch_pos]}"
      _pos=$((_pos + 1))
      _n="${_STEP_NUMBERS[$_i]}"
      _name="${_STEP_NAMES[$_i]}"
      _id="${_STEP_IDS[$_i]}"
      _started=$((_started + 1))
      _runner_steps_started="$_started"
      _run_step "$_n" "$_name" "${_STEP_FUNCS[$_i]}" "$_id" "${POSITIONAL_ARGS[@]+${POSITIONAL_ARGS[@]}}" &
      _run_pids+=($!)
      _run_positions+=("$_launch_pos")
      _launched_positions+=("$_launch_pos")
      printf '%s[%d/%d] step %s %s started%s\n' "${_nuc_c1_dim}" "$_started" "$_total" "$_n" "$_name" "${_nuc_c1_reset}"
    done

    [ "${#_run_pids[@]}" -eq 0 ] && break

    _reaped_any=false
    for _k in "${!_run_pids[@]}"; do
      if kill -0 "${_run_pids[$_k]}" 2>/dev/null; then
        # WHY: a zombie still exists, so kill -0 returns 0; reap it or it lingers.
        # check-suppress:suppression_doc: ps exits non-zero when the pid vanished between kill -0 and the state probe
        case "$(ps -o state= -p "${_run_pids[$_k]}" 2>/dev/null || true)" in
        Z*) ;;
        *) continue ;;
        esac
      fi
      _reaped_any=true
      _wait_ret=0
      wait "${_run_pids[$_k]}" || _wait_ret=$?
      _launch_pos="${_run_positions[$_k]}"
      _n="${_STEP_NUMBERS[${_pending_indices[$_launch_pos]}]}"
      printf '%sstep %s finished (%s)%s\n' "${_nuc_c1_dim}" "$_n" \
        "$(_format_duration_s "$(cat "$_wave_tmpdir/step-$_n.time" 2>/dev/null || echo 0)")" "${_nuc_c1_reset}"
      unset "_run_pids[$_k]" "_run_positions[$_k]"
      if [ "$_wait_ret" -ne 0 ] && $FAIL_FAST; then
        _failed_positions[$_launch_pos]=1
        _stop_launching=true
      fi
    done
    $_reaped_any && continue

    sleep "$_tick_seconds"
    _ticks=$((_ticks + 1))
    if [ "$_ticks_per_progress" -gt 0 ] && [ "$_ticks" -ge "$_ticks_per_progress" ]; then
      _ticks=0
      for _k in "${!_run_pids[@]}"; do
        _launch_pos="${_run_positions[$_k]}"
        _n="${_STEP_NUMBERS[${_pending_indices[$_launch_pos]}]}"
        printf '%sstep %s still running (%s)%s\n' "${_nuc_c1_dim}" "$_n" \
          "$(_format_duration_s $(($(_step_now_ms) - $(cat "$_wave_tmpdir/step-$_n.start" 2>/dev/null || echo 0))))" "${_nuc_c1_reset}"
      done
    fi
  done

  if $_stop_launching; then
    # In-flight steps have drained; report the failed set in launch order.
    for _k in "${_launched_positions[@]}"; do
      if [ -n "${_failed_positions[$_k]+x}" ]; then
        _fail_fast_indices+=("${_pending_indices[$_k]}")
      fi
    done
    _report_fail_fast "${_fail_fast_indices[@]}"
    exit 1
  fi

  printf '%s' $(($(_step_now_ms) - _pipeline_start_ms)) >"$_wave_tmpdir/pipeline.wall_ms"
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
  local _i _id _tool
  for _i in "${!_STEP_IDS[@]}"; do
    _id="${_STEP_IDS[$_i]}"
    if [ -n "$(_step_run_state "$_id" "${_STEP_PLATFORMS[$_i]}" "${_STEP_MODES[$_i]}" "${_STEP_REQUIRES[$_i]}")" ]; then
      continue
    fi
    for _tool in ${_STEP_TOOLS[$_i]}; do
      require_command "$_tool"
    done
  done
  # WHY: deny-list.sh shells out to git for gitignore filtering in the runner itself,
  # before any step runs, so this is a runner prerequisite rather than a step tool.
  require_command git
}
