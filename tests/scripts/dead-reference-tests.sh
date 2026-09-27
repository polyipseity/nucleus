#!/usr/bin/env bash
# WHY: grep-based — the defect guarded here is a rename that did not reach the
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

# This file names the dead filename twice by design — once in the header that
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
# stay silent — which is how the parked Sync-LiteLLMService finding survived a
# review that had already looked at this file. This rule forbids `env-catalog`
# followed by a file extension (a path reference) while leaving the bare
# concept alone, because "services, env-catalog, config paths" in
# host-platform-naming.reference.md is correct English and not a citation.
_dead_env_catalog_paths() {
  git -C "$REPO_ROOT" grep -nE -- 'env-catalog\.[A-Za-z0-9]+' -- . ":(exclude)$_SELF" 2>/dev/null || true
}

# The one known exception, pinned rather than waved through. Sync-LiteLLMService
# copies an env-catalog.json that does not exist and nothing generates it; the
# controller parked that as an operator decision rather than deleting code whose
# Windows behaviour cannot be verified from here. Pinned as exact
# file:line:text so it cannot widen into a blanket suppression: fix, delete or
# reword any of the four and the pinned set stops matching, which fails here.
_PARKED_DEAD_PATHS=$(
  cat <<'PARK_EOF'
src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1:129:  # Copy static env-catalog.json
src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1:130:  $catalogSource = Join-Path -Path $RepoRoot
src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1:131:  $catalogPath = Join-Path -Path $env:LOCALAPPDATA
src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1:188:  $catalogPath = Join-Path -Path $env:LOCALAPPDATA
PARK_EOF
)

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

# Rule B's scan swallows stderr and an empty result reads as a pass, so it needs
# the same liveness guard Rule A's scan has above: a malformed `:(exclude)`
# pathspec or a `git grep -E` failure would otherwise be indistinguishable from a
# clean tree. The four parked Sync-LiteLLMService lines are known-present, so a
# live scan must find at least one — that turns an inert scan into a failure.
_dead_env_catalog_paths_is_live() {
  local _probe
  _probe="$(_dead_env_catalog_paths | grep -c . || true)"
  if [ "${_probe:-0}" -gt 0 ]; then
    assert_pass "dead env-catalog path scan sees the pinned parked findings ($_probe lines)"
  else
    assert_fail "dead env-catalog path scan sees tracked files" "git grep found no env-catalog path; the scan cannot be trusted"
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

# Rule B's assertion. Every hit must be one of the pinned parked lines, so a new
# dead env-catalog path anywhere fails here. A substring allowlist that also
# performs the matching would be circular; these are exact file:line:text.
_fewer_dead_env_catalog_paths() {
  local _hits _unapproved="" _count _first _line _p _is_pinned
  _hits="$(_dead_env_catalog_paths)"
  if [ -z "$_hits" ]; then
    assert_pass "no dead env-catalog path survives outside the pinned park"
    return
  fi
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _is_pinned=0
    while IFS= read -r _p; do
      [ -z "$_p" ] && continue
      case "$_line" in
      "$_p"*)
        _is_pinned=1
        break
        ;;
      esac
    done <<<"$_PARKED_DEAD_PATHS"
    [ "$_is_pinned" -eq 1 ] || _unapproved="$_unapproved$_line"$'\n'
  done <<<"$_hits"
  if [ -z "$_unapproved" ]; then
    _count="$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')"
    assert_pass "every dead env-catalog path is a pinned parked finding ($_count pinned)"
  else
    _count="$(printf '%s' "$_unapproved" | grep -c . || true)"
    _first="$(printf '%s' "$_unapproved" | head -1)"
    assert_fail "every dead env-catalog path is pinned" "$_count unpinned, first: $_first"
  fi
}

_scan_is_live
_ssot_resolves
_no_dead_citation_survives
_dead_env_catalog_paths_is_live
_fewer_dead_env_catalog_paths
finish_tests
