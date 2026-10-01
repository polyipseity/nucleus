#!/usr/bin/env bash
# WHY: grep-based: the defect guarded here is a rename that did not reach the
# text citing it. src/modules/lib/env-catalog.nix became env-secrets.nix
# (72f1e7de), but 28 citations across 10 tracked files kept the old name, and
# nothing reported them. An agent reading one of those citations is pointed at
# a file that does not exist, and a "Nix-side source of truth" pointer that
# resolves to nothing is worse than no pointer.
#
# The guard is the filename, not the concept: "env catalog" remains the
# correct name for the thing, and the concept is legitimately used as a word in
# prose. Only the dead *filename* is forbidden.
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEAD_FILENAME="env-catalog.nix"
SSOT="src/modules/lib/env-secrets.nix"

require_command git "the citation scan enumerates tracked files with git grep"

# This file names the dead filename twice by design, once in the header that
# explains the defect, once in the DEAD_FILENAME constant that drives the scan.
# Both scans therefore exclude this path explicitly. Without the exclusion the
# suite is green only while the file is untracked, because `git grep` reads
# tracked files: the moment the controller commits it, the guard finds its own
# two lines and fails. Simulated with `git grep --no-index`.
_SELF="tests/scripts/dead-reference-tests.sh"

# Every tracked file still citing the dead filename, as file:line. git grep
# rather than a plain walk so untracked scratch and .git never contribute.
_dead_citations() {
  git -C "$REPO_ROOT" grep -n -- "$DEAD_FILENAME" -- . ":(exclude)$_SELF" 2>/dev/null || true
}

# Rule B. Rule A forbids only the one filename this branch happened to rename.
# A rename can equally break a .json, .yml or .ps1 reference and Rule A would
# stay silent, which is how the parked Sync-LiteLLMService finding survived a
# review that had already looked at this file. This rule forbids `env-catalog`
# followed by a file extension (a path reference) while leaving the bare
# concept alone, because "services, env-catalog, config paths" in
# host-platform-naming.reference.md is correct English and not a citation.
_dead_env_catalog_paths() {
  git -C "$REPO_ROOT" grep -nE -- 'env-catalog\.[A-Za-z0-9]+' -- . ":(exclude)$_SELF" 2>/dev/null || true
}

# The former park is gone. Sync-LiteLLMService copied an env-catalog.json that
# did not exist and nothing generated it; the operator ruled it outdated code and
# directed parity with POSIX, so the module now selects its keys from
# src/modules/env/env-secrets.json -- the same catalog and the same consumer
# filter envLib.mkSecretArgsForConsumer applies. The dead path is gone from the
# tree, so Rule B below is now zero-tolerance: no pin, no exception, any hit at
# all fails. That is strictly stronger than pinning four known lines, which
# could have been satisfied while a fifth dead reference went unexamined.

# The scan must be able to fail. If the file list were empty, or if the search
# were malformed, the loop below would never run and the suite would report
# green while guarding nothing. Asserting a known-good citation exists first
# makes an inert scan a failure instead of a pass.
_scan_is_live() {
  local _probe
  _probe="$(git -C "$REPO_ROOT" grep -c -- "$SSOT" -- . 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$_probe" -gt 0 ]; then
    assert_pass "citation scan sees tracked files ($SSOT cited in $_probe files)"
  else
    assert_fail "citation scan sees tracked files" "git grep found no file citing $SSOT; the scan cannot be trusted"
  fi
}

# Rule B's own scan needs the same guard now that its known hits are gone. It
# swallows stderr and an empty result reads as a pass, so a malformed
# `:(exclude)` pathspec or a failing `git grep -E` would be indistinguishable
# from a clean tree. The replacement probe is a path pattern that MUST match the
# citation Sync-LiteLLMService now carries, run through the same -E and the same
# pathspec, so the machinery is exercised even though the rule is idle.
_dead_env_catalog_paths_is_live() {
  local _probe
  _probe="$(git -C "$REPO_ROOT" grep -cE -- 'env-secrets\.json' -- . 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${_probe:-0}" -gt 0 ]; then
    assert_pass "dead env-catalog path scan machinery works (env-secrets.json cited in $_probe files)"
  else
    assert_fail "dead env-catalog path scan machinery works" "git grep -E found no env-secrets.json path; the scan cannot be trusted"
  fi
}

_ssot_resolves() {
  if [ -f "$REPO_ROOT/$SSOT" ]; then
    assert_pass "the cited source of truth exists ($SSOT)"
  else
    assert_fail "the cited source of truth exists" "no such file: $SSOT"
  fi
  if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$SSOT" >/dev/null 2>&1; then
    assert_pass "the cited source of truth is tracked ($SSOT)"
  else
    assert_fail "the cited source of truth is tracked" "untracked: $SSOT"
  fi
}

_no_dead_citation_survives() {
  local _hits _count _first
  _hits="$(_dead_citations)"
  if [ -z "$_hits" ]; then
    assert_pass "no tracked file cites the dead filename $DEAD_FILENAME"
  else
    _count="$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')"
    _first="$(printf '%s\n' "$_hits" | head -1)"
    assert_fail "no tracked file cites the dead filename $DEAD_FILENAME" "$_count surviving, first: $_first"
  fi
}

# Rule B's assertion. Zero tolerance: the last known dead path has been fixed, so
# any surviving env-catalog.<ext> anywhere in the tree is a regression. There is
# no longer an allowlist to match against, which removes the circularity a
# substring allowlist would have had.
_fewer_dead_env_catalog_paths() {
  local _hits _count _first
  _hits="$(_dead_env_catalog_paths)"
  if [ -z "$_hits" ]; then
    assert_pass "no dead env-catalog path survives anywhere in the tree"
  else
    _count="$(printf '%s\n' "$_hits" | grep -c . || true)"
    _first="$(printf '%s\n' "$_hits" | head -1)"
    assert_fail "no dead env-catalog path survives" "$_count found, first: $_first"
  fi
}

_scan_is_live
_ssot_resolves
_no_dead_citation_survives
_dead_env_catalog_paths_is_live
_fewer_dead_env_catalog_paths
finish_tests
