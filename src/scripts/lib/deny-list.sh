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
#   128 — fatal error (e.g., not a git repository)
#
# On fatal error (exit 128), the full input passes through unchanged.
# On exit 0, the ignored paths are subtracted from the input.
# On exit 1 (nothing ignored), the full input passes through.
filter_gitignored() {
  if [ ! -d .git ] && [ -z "${GIT_DIR:-}" ]; then
    # Not a git repository — pass through everything
    cat
    return
  fi
  local _tmp _git_exit=0
  _tmp=$(mktemp) || return 1
  cat > "$_tmp"
  [ ! -s "$_tmp" ] && { rm -f "$_tmp"; return; }
  # Batch check via stdin. Capture output to temp file so pipefail
  # does not interfere with the exit code check.
  git check-ignore --stdin < "$_tmp" 2>/dev/null > "$_tmp.ignored"; _git_exit=$?
  if [ "$_git_exit" -gt 1 ]; then
    # git error (exit 128) — pass through unchanged
    cat "$_tmp"
  elif [ -s "$_tmp.ignored" ]; then
    # Some paths were ignored — subtract them from the input
    grep -v -F -x -f "$_tmp.ignored" "$_tmp" 2>/dev/null || true
  else
    # Nothing ignored (exit 1 with empty output) — pass through
    cat "$_tmp"
  fi
  rm -f "$_tmp" "$_tmp.ignored"
}

# find_git_tracked — wraps `find` and pipes through filter_gitignored.
# Passes all arguments directly to `find`. Results exclude gitignored files.
find_git_tracked() {
  find "$@" -print | filter_gitignored
}
