#!/usr/bin/env bash
# WHY: grep-based: the defect guarded here is a divergence between the ai
# twins: each declares its own model manifest path, and nothing reported the
# disagreement. The broken path lives in the Windows script, which no POSIX
# gate can invoke, so the only observable surface is the two sources compared
# against each other and against the working tree.
#
# Every assertion runs over *all* paths a twin declares, not just the first.
# A script can carry a correct assignment and then a second, wrong one that
# wins at runtime, so a first-match-only guard reads green on a broken script.
# No path is hardcoded: each twin's declared path is extracted and resolved, so
# renaming the manifest later is caught without editing this suite.
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AI_SH="$REPO_ROOT/scripts/ai.sh"
AI_PS1="$REPO_ROOT/scripts/ai.ps1"

require_command git "the tracked-file assertion runs git ls-files"

# The paths ai.sh hands to jq, forward slashes as written, one per line. The
# trailing .*$ is deliberate: ai.ps1 is CRLF per .gitattributes, so a $ anchor
# would never match there, and a twin comparison must not depend on line-ending
# style.
_ai_sh_manifests() {
  # shellcheck disable=SC2016 # reason: $REPO_ROOT is a literal in the sed pattern, not shell expansion
  sed -n 's/^[[:space:]]*MANIFEST="\$REPO_ROOT\/\([^"]*\)".*$/\1/p' "$AI_SH"
}

# The paths ai.ps1 hands to Test-Path, normalised from backslashes so they
# compare with the sh twin and resolve against the tree.
_ai_ps1_manifests() {
  # shellcheck disable=SC2016 # reason: $ModelsJson and $RepoRoot are literals in the sed pattern, not shell expansion
  sed -n 's/^[[:space:]]*\$ModelsJson[[:space:]]*=[[:space:]]*Join-Path[[:space:]]*\$RepoRoot[[:space:]]*"\([^"]*\)".*$/\1/p' "$AI_PS1" |
    sed 's|\\|/|g'
}

# WHY scoped to the <# ... #> block: searching the whole file returns the
# *assignment* rather than the documented path, and a test that compares the code
# against itself then passes whatever the code says.
# Scoped to every comment block, not just the first, so this twin and the .ps1
# twin agree on which lines are eligible; a second block added later must not make
# them diverge silently.
# Empty when the help text does not mention one, which is not a failure on its own.
# awk rather than `grep | head -1` because a no-match grep exits non-zero, which
# would abort the suite outright under `set -e` and make the empty case unreachable.
_ai_ps1_documented_manifest() {
  awk '
    /^<#/ { in_help = 1; next }
    /^#>/ { in_help = 0 }
    in_help && match($0, /[A-Za-z0-9_.\/-]*models\.json/) { print substr($0, RSTART, RLENGTH); exit }
  ' "$AI_PS1"
}

# Deduplicated, sorted form of a path list, so two twins can be compared as
# sets: declaring the same paths in a different order is not a divergence.
_ai_normalize() {
  printf '%s\n' "$1" | sed '/^$/d' | sort -u
}

# The two lists as one deduplicated, sorted set.
_ai_union() { # <list> <list>
  { printf '%s\n%s\n' "$1" "$2"; } | sed '/^$/d' | sort -u
}

# The loops below read their list through a here-string, not a pipe: a piped
# while-loop runs in a subshell and the counters in test-lib.sh would not
# survive it.

test_ai_manifest_paths_resolve() {
  local _sh _ps1 _path
  _sh="$(_ai_sh_manifests)"
  _ps1="$(_ai_ps1_manifests)"
  if [ -z "$_sh" ]; then
    # shellcheck disable=SC2016 # reason: the message quotes the literal text it is looking for
    assert_fail "ai.sh declares a manifest path" 'no MANIFEST="$REPO_ROOT/..." assignment'
  else
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if [ -f "$REPO_ROOT/$_path" ]; then
        assert_pass "ai.sh manifest path resolves ($_path)"
      else
        assert_fail "ai.sh manifest path resolves" "no such file: $_path"
      fi
    done <<<"$_sh"
  fi
  if [ -z "$_ps1" ]; then
    # shellcheck disable=SC2016 # reason: the message quotes the literal text it is looking for
    assert_fail "ai.ps1 declares a manifest path" 'no $ModelsJson = Join-Path $RepoRoot "..." assignment'
  else
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if [ -f "$REPO_ROOT/$_path" ]; then
        assert_pass "ai.ps1 manifest path resolves ($_path)"
      else
        assert_fail "ai.ps1 manifest path resolves" "no such file: $_path"
      fi
    done <<<"$_ps1"
  fi
}

test_ai_manifest_paths_are_tracked() {
  local _candidates _path
  _candidates="$(_ai_union "$(_ai_sh_manifests)" "$(_ai_ps1_manifests)")"
  # An empty set would pass vacuously through a loop that never runs, so the
  # empty case is a failure of this assertion rather than of nothing.
  if [ -z "$_candidates" ]; then
    assert_fail "ai manifest paths are tracked files" "no manifest path extracted from either twin"
  else
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$_path" >/dev/null 2>&1; then
        assert_pass "ai manifest path is tracked ($_path)"
      else
        assert_fail "ai manifest path is tracked" "untracked: $_path"
      fi
    done <<<"$_candidates"
  fi
}

test_ai_manifest_paths_agree_across_twins() {
  local _sh _ps1 _sh_set _ps1_set _sh_flat _ps1_flat
  _sh="$(_ai_sh_manifests)"
  _ps1="$(_ai_ps1_manifests)"
  if [ -z "$_sh" ] || [ -z "$_ps1" ]; then
    assert_fail "ai twins declare the same manifest paths" 'extraction failed on at least one twin'
  else
    _sh_set="$(_ai_normalize "$_sh")"
    _ps1_set="$(_ai_normalize "$_ps1")"
    _sh_flat="$(printf '%s' "$_sh_set" | tr '\n' ' ')"
    _ps1_flat="$(printf '%s' "$_ps1_set" | tr '\n' ' ')"
    if [ "$_sh_set" = "$_ps1_set" ]; then
      assert_pass "ai twins declare the same manifest paths ($_ps1_flat)"
    else
      assert_fail "ai twins declare the same manifest paths" "ai.sh=[$_sh_flat] ai.ps1=[$_ps1_flat]"
    fi
  fi
}

test_ai_ps1_documented_manifest_agrees() {
  local _ps1 _documented _path
  _ps1="$(_ai_ps1_manifests)"
  _documented="$(_ai_ps1_documented_manifest)"
  if [ -z "$_ps1" ]; then
    assert_fail "ai.ps1 help text agrees with the code" 'code path not extractable'
  elif [ -z "$_documented" ]; then
    assert_pass "ai.ps1 help text declares no manifest path, so nothing to contradict"
  else
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if [ "$_path" = "$_documented" ]; then
        assert_pass "ai.ps1 help text agrees with the code ($_path)"
      else
        assert_fail "ai.ps1 help text agrees with the code" "help=$_documented code=$_path"
      fi
    done <<<"$_ps1"
  fi
}

test_ai_manifest_paths_resolve
test_ai_manifest_paths_are_tracked
test_ai_manifest_paths_agree_across_twins
test_ai_ps1_documented_manifest_agrees
finish_tests
