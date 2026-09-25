#!/usr/bin/env bash
# Check-specific framework library.
# Sources step-runner.sh and sets check-specific defaults.
#
# Guard against re-sourcing — step files source this independently and
# re-sourcing would overwrite SCRIPT_DIR and REPO_ROOT.
[ -n "${_NUCLEUS_CHECK_LIB_SOURCED-}" ] && return
_NUCLEUS_CHECK_LIB_SOURCED=1

# Resolve SCRIPT_DIR relative to this file so it works when sourced from
# standalone step files without a pre-set SCRIPT_DIR.
_self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)

_NUCLEUS_LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/lib.sh
. "$_NUCLEUS_LIB_DIR/lib.sh"
# shellcheck source=../lib/step-runner.sh
. "$_NUCLEUS_LIB_DIR/step-runner.sh"

# Check-specific defaults
export FAIL_FAST=false
REPO_ROOT=$(derive_repo_root)
export NUCLEUS_REPO_ROOT="$REPO_ROOT"
cd "$REPO_ROOT" || exit

# Discover files in a directory tree, applying gitignore filter.
# Usage: discover_files _out_array repo_root dir extensions_csv
# extensions_csv: comma-separated glob patterns (e.g. "*.nix" or "*.sh,*.zsh")
discover_files() {
  local -n _df_out="$1"
  local _df_root="$2" _df_dir="$3" _df_exts="$4"
  local IFS=','
  read -ra _df_ext_list <<<"$_df_exts"
  local _df_find_args=()
  local _df_ext
  for _df_ext in "${_df_ext_list[@]}"; do
    _df_find_args+=(-name "$_df_ext" -o)
  done
  unset '_df_find_args[${#_df_find_args[@]}-1]'
  while IFS= read -r -d '' _df_f; do
    _df_out+=("$_df_f")
  done < <(find "$_df_root/$_df_dir" -type f \( "${_df_find_args[@]}" \) -not -path '*/vendor/*' -print0)
  mapfile -t _df_out < <(printf '%s\n' "${_df_out[@]}" | filter_gitignored)
}

# Filter positional args by directory prefix and extension.
# Usage: filter_scoped_files _out_array files[@] dir extensions_csv
filter_scoped_files() {
  local -n _fsf_out="$1"
  shift
  local _fsf_dir="$1" _fsf_exts="$2"
  shift 2
  local IFS=','
  read -ra _fsf_ext_list <<<"$_fsf_exts"
  local _fsf_f _fsf_base _fsf_ext
  for _fsf_f in "$@"; do
    case "$_fsf_f" in
    "$_fsf_dir"/*)
      _fsf_base="${_fsf_f##*/}"
      for _fsf_ext in "${_fsf_ext_list[@]}"; do
        # Strip leading * from glob for case match
        local _fsf_pat="${_fsf_ext#\*}"
        case "$_fsf_base" in
        *"$_fsf_pat")
          _fsf_out+=("$_fsf_f")
          break
          ;;
        esac
      done
      ;;
    esac
  done
}

# Run a step's sub-checks in declared order, announcing each label and failing the
# whole step when any sub-check fails.
# Usage: run_policy_checks <ctx-name> <step-label> <spec-array-name> [files ...]
#   A spec is "<label>|<function>|<style>": "ctx" passes the context name to the
#   sub-check, "files" passes the context's HAS_ARGS and REPO_ROOT. Sub-checks keep
#   their signatures, so each stays callable on its own against a fixture tree.
run_policy_checks() {
  local _rpc_ctx="$1" _rpc_label="$2" _rpc_specs="$3"
  # shellcheck disable=SC2178 # reason: namerefs to the caller's context and spec array
  local -n _rpc_context="$_rpc_ctx"
  # shellcheck disable=SC2178 # reason: nameref to the caller's spec array
  local -n _rpc_spec_list="$_rpc_specs"
  shift 3
  local _failed=0 _spec _label _func _style
  for _spec in "${_rpc_spec_list[@]}"; do
    _label="${_spec%%|*}"
    _spec="${_spec#*|}"
    _func="${_spec%%|*}"
    _style="${_spec##*|}"
    say "--- $_label ---"
    case "$_style" in
    ctx) "$_func" "$_rpc_ctx" "$@" || _failed=1 ;;
    files) "$_func" "${_rpc_context[HAS_ARGS]}" "${_rpc_context[REPO_ROOT]}" "$@" || _failed=1 ;;
    *)
      error "run_policy_checks: unknown style '$_style' in spec '$_label|$_func|$_style'"
      return 1
      ;;
    esac
  done
  if [ "$_failed" -ne 0 ]; then
    error "$_rpc_label check failed"
    return 1
  fi
  say "$_rpc_label passed."
  return 0
}

usage() {
  usage_std "check.sh" "[--fail-fast|--no-fail-fast] [--scoped|--full] [--online] [--verbose[=<ids>]] [--no-verbose] [--only-steps=<ids>] [path ...]" "Run all repository validation checks with parallel step dispatch (capped at PARALLEL_JOBS). Use --scoped to skip whole-repo checks (path-scoped mode), --full to force whole-repo checks even with paths. Default: scoped if paths given, full otherwise. With arguments, passes paths through to supporting checkers. Use --fail-fast to exit immediately on first failure (default: accumulate all). Use --no-fail-fast to accumulate all failures (default). Use --online to additionally run online determinism checks (requires network). Use --verbose to stream all step output (default: headers + summaries only). Use --verbose=<ids> to stream only specified step IDs. Use --no-verbose to suppress streaming (default). Use --only-steps=<ids> to run only the steps with the given comma-separated IDs."
}
