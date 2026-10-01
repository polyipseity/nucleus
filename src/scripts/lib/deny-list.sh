#!/usr/bin/env bash
# Gitignore-aware denylist library for POSIX shell, sourced by step-runner.sh
# and check-lib.sh. filter_gitignored drops the paths git ignores;
# find_git_tracked runs find through the same filter.
#
# Guard against re-sourcing.
[ -n "${_NUCLEUS_DENY_LIST_SOURCED-}" ] && return
_NUCLEUS_DENY_LIST_SOURCED=1

# Usage:
#   . "$SCRIPT_DIR/../lib/deny-list.sh"
#   filter_gitignored < file_list.txt
#   find . -name '*.nix' -print | filter_gitignored
#
# filter_gitignored reads paths from stdin and writes non-gitignored paths to
# stdout through `git check-ignore --stdin`.
#
# check-ignore exit status: 0 some path ignored (output lists them), 1 none
# ignored (output empty), 128 fatal (not a repo, or a pathspec beyond a symlink).
#
# A pathspec beyond a symlink fails the WHOLE batch, so one such path would
# disarm the filter for the rest. Those paths are dropped and the query repeats;
# a dropped path carries no ignore status and the file it shadows is enumerated
# at its real path, so it leaves the result. A round naming no pathspec this
# batch holds is a plain failure: the full input passes through unchanged, which
# is what keeps the loop finite.
# On exit 0 the ignored paths are subtracted from the input; on exit 1 the full
# input passes through.
filter_gitignored() {
  if [ ! -d .git ] && [ -z "${GIT_DIR:-}" ]; then
    # Not a git repository, pass everything through
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
  # WHY a temp file: piping the output would let pipefail interfere with the
  #   exit code check.
  # WHY `||` (not `;`): git exits 1 when nothing is ignored, and outside a
  #   conditional `set -e` aborts this subshell before `_git_exit=$?` reads it,
  #   leaving callers with empty file lists.
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
    # exit 128 with no resolvable pathspec, pass through unchanged
    cat "$_tmp"
  elif [ -s "$_tmp.ignored" ]; then
    # Some paths ignored, subtract them from the input
    grep -v -F -x -f "$_tmp.ignored" "$_tmp" 2>/dev/null || true # check-suppress:suppression_doc: grep -v exits 1 when every path is ignored; an empty result is handled by the caller
  else
    # Nothing ignored, pass through
    cat "$_tmp"
  fi
  rm -f "$_tmp" "$_tmp.ignored" "$_err" "$_tmp.next"
}

# find_git_tracked wraps `find`, passing every argument through, and pipes the
# result through filter_gitignored.
find_git_tracked() {
  find "$@" -print | filter_gitignored
}
