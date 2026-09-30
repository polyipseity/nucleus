#!/usr/bin/env bash
# Gitignore-aware denylist library for POSIX shell.
# Provides functions to filter out gitignored paths from file lists.
# Sourced by step-runner.sh and check-lib.sh.
#
# Guard against re-sourcing.
[ -n "${_NUCLEUS_DENY_LIST_SOURCED-}" ] && return
_NUCLEUS_DENY_LIST_SOURCED=1

# Usage:
#   . "$SCRIPT_DIR/../lib/deny-list.sh"
#   filter_gitignored < file_list.txt
#   find . -name '*.nix' -print | filter_gitignored

# filter_gitignored — reads paths from stdin (one per line), writes
# non-gitignored paths to stdout. Uses git check-ignore --stdin for
# batch-mode efficiency.
#
# Exit behavior of git check-ignore --stdin:
#   0  — at least one path was ignored (output lists those paths)
#   1  — no paths were ignored (output is empty)
#   128 — fatal error (e.g., not a git repository), or one pathspec lies
#         beyond a symbolic link
#
# A pathspec beyond a symlink fails the WHOLE batch, so one such path would
# disarm the filter for every other path. Those paths are dropped and the query
# repeats; a dropped path carries no ignore status, and the file it shadows is
# enumerated at its real path, so it leaves the result. A round that names no
# pathspec this batch actually holds is a plain failure: the full input passes
# through unchanged, and that is what keeps the loop finite.
# On exit 0, the ignored paths are subtracted from the input.
# On exit 1 (nothing ignored), the full input passes through.
filter_gitignored() {
  if [ ! -d .git ] && [ -z "${GIT_DIR:-}" ]; then
    # Not a git repository — pass through everything
    cat
    return
  fi
  local _tmp _err _dropped _git_exit=0
  _tmp=$(mktemp) || return 1
  _err=$(mktemp) || {
    rm -f "$_tmp"
    return 1
  }
  cat >"$_tmp"
  [ ! -s "$_tmp" ] && {
    rm -f "$_tmp" "$_err"
    return
  }
  # Batch check via stdin. Capture output to temp file so pipefail
  # does not interfere with the exit code check.
  # `||` (not `;`) is required: git exits 1 when nothing is ignored, and
  # without the conditional context `set -e` aborts this subshell before
  # `_git_exit=$?` captures it — leaving callers with empty file lists.
  while :; do
    _git_exit=0
    : >"$_err"
    git check-ignore --stdin <"$_tmp" 2>"$_err" >"$_tmp.ignored" || _git_exit=$?
    [ "$_git_exit" -le 1 ] && break
    _dropped=$(sed -n "s/^fatal: pathspec '\(.*\)' is beyond a symbolic link$/\1/p" "$_err" |
      grep -F -x -f "$_tmp" || true) # check-suppress:suppression_doc: sed/grep exit non-zero when no beyond-a-symlink pathspec matches this batch; the empty result means a plain fatal error
    [ -n "$_dropped" ] || break
    grep -v -F -x -f <(printf '%s\n' "$_dropped") "$_tmp" >"$_tmp.next" || true # check-suppress:suppression_doc: grep -v exits 1 when every path is dropped, leaving an empty batch that the next round reports as nothing left to check
    mv "$_tmp.next" "$_tmp"
  done
  if [ "$_git_exit" -gt 1 ]; then
    # git error (exit 128) with no resolvable pathspec — pass through unchanged
    cat "$_tmp"
  elif [ -s "$_tmp.ignored" ]; then
    # Some paths were ignored — subtract them from the input
    grep -v -F -x -f "$_tmp.ignored" "$_tmp" 2>/dev/null || true # check-suppress:suppression_doc: grep -v exits 1 when every path is ignored; an empty result is handled by the caller
  else
    # Nothing ignored (exit 1 with empty output) — pass through
    cat "$_tmp"
  fi
  rm -f "$_tmp" "$_tmp.ignored" "$_err" "$_tmp.next"
}

# find_git_tracked — wraps `find` and pipes through filter_gitignored.
# Passes all arguments directly to `find`. Results exclude gitignored files.
find_git_tracked() {
  find "$@" -print | filter_gitignored
}
