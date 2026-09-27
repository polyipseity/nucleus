#!/usr/bin/env bash
# WHY: grep-based — the defect guarded here is a divergence between the ai
# twins: each resolves its own model manifest path, and nothing reported the
# disagreement. The broken path lives in the Windows script, which no POSIX
# gate can invoke, so the only observable surface is the two sources compared
# against each other and against the working tree. Each assertion extracts the
# path a twin actually resolves and checks that file exists, so renaming the
# manifest later is caught without this suite hardcoding the current name.
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AI_SH="$REPO_ROOT/scripts/ai.sh"
AI_PS1="$REPO_ROOT/scripts/ai.ps1"

# The path ai.sh hands to jq, forward slashes as written. The trailing .*$ is
# deliberate: ai.ps1 is CRLF per .gitattributes, so a $ anchor would never match
# there, and a twin comparison must not depend on line-ending style.
_ai_sh_manifest() {
  # shellcheck disable=SC2016 # reason: $REPO_ROOT is a literal in the sed pattern, not shell expansion
  sed -n 's/^[[:space:]]*MANIFEST="\$REPO_ROOT\/\([^"]*\)".*$/\1/p' "$AI_SH" | head -1
}

# The path ai.ps1 hands to Test-Path, normalised from backslashes so it can be
# compared with the sh twin and resolved against the tree.
_ai_ps1_manifest() {
  # shellcheck disable=SC2016 # reason: $ModelsJson and $RepoRoot are literals in the sed pattern, not shell expansion
  sed -n 's/^[[:space:]]*\$ModelsJson[[:space:]]*=[[:space:]]*Join-Path[[:space:]]*\$RepoRoot[[:space:]]*"\([^"]*\)".*$/\1/p' "$AI_PS1" |
    head -1 | sed 's|\\|/|g'
}

# The manifest path as ai.ps1's own help text declares it. Empty when the help
# text does not mention one, which is not a failure on its own. awk rather than
# `grep | head -1` because a no-match grep exits non-zero, which would abort
# the suite outright under `set -e` and make the empty case unreachable.
_ai_ps1_documented_manifest() {
  awk 'match($0, /[A-Za-z0-9_.\/-]*models\.json/) { print substr($0, RSTART, RLENGTH); exit }' "$AI_PS1"
}

test_ai_manifest_paths_resolve() {
  local sh_path ps1_path
  sh_path="$(_ai_sh_manifest)"
  ps1_path="$(_ai_ps1_manifest)"

  if [ -z "$sh_path" ]; then
    # shellcheck disable=SC2016 # reason: the message quotes the literal text it is looking for
    assert_fail "ai.sh manifest path is extractable" 'no MANIFEST="$REPO_ROOT/..." assignment'
  elif [ -f "$REPO_ROOT/$sh_path" ]; then
    assert_pass "ai.sh manifest path resolves ($sh_path)"
  else
    assert_fail "ai.sh manifest path resolves" "no such file: $sh_path"
  fi

  if [ -z "$ps1_path" ]; then
    # shellcheck disable=SC2016 # reason: the message quotes the literal text it is looking for
    assert_fail "ai.ps1 manifest path is extractable" 'no $ModelsJson = Join-Path $RepoRoot "..." assignment'
  elif [ -f "$REPO_ROOT/$ps1_path" ]; then
    assert_pass "ai.ps1 manifest path resolves ($ps1_path)"
  else
    assert_fail "ai.ps1 manifest path resolves" "no such file: $ps1_path"
  fi
}

test_ai_manifest_paths_are_tracked() {
  local sh_path ps1_path
  sh_path="$(_ai_sh_manifest)"
  ps1_path="$(_ai_ps1_manifest)"
  local _bad=""

  [ -n "$sh_path" ] && ! git -C "$REPO_ROOT" ls-files --error-unmatch -- "$sh_path" >/dev/null 2>&1 && _bad="ai.sh: $sh_path"
  [ -n "$ps1_path" ] && ! git -C "$REPO_ROOT" ls-files --error-unmatch -- "$ps1_path" >/dev/null 2>&1 && _bad="${_bad:+$_bad, }ai.ps1: $ps1_path"

  if [ -z "$_bad" ]; then
    assert_pass "ai manifest paths are tracked files"
  else
    assert_fail "ai manifest paths are tracked files" "untracked: $_bad"
  fi
}

test_ai_manifest_paths_agree_across_twins() {
  local sh_path ps1_path
  sh_path="$(_ai_sh_manifest)"
  ps1_path="$(_ai_ps1_manifest)"

  if [ -z "$sh_path" ] || [ -z "$ps1_path" ]; then
    assert_fail "ai twins resolve the same manifest" 'extraction failed on at least one twin'
  elif [ "$sh_path" = "$ps1_path" ]; then
    assert_pass "ai twins resolve the same manifest ($ps1_path)"
  else
    assert_fail "ai twins resolve the same manifest" "ai.sh=$sh_path ai.ps1=$ps1_path"
  fi
}

test_ai_ps1_documented_manifest_agrees() {
  local ps1_path documented
  ps1_path="$(_ai_ps1_manifest)"
  documented="$(_ai_ps1_documented_manifest)"

  if [ -z "$documented" ]; then
    assert_pass "ai.ps1 help text declares no manifest path, so nothing to contradict"
  elif [ -z "$ps1_path" ]; then
    assert_fail "ai.ps1 documented manifest agrees with the code" 'code path not extractable'
  elif [ "$documented" = "$ps1_path" ]; then
    assert_pass "ai.ps1 help text agrees with the code ($ps1_path)"
  else
    assert_fail "ai.ps1 help text agrees with the code" "help=$documented code=$ps1_path"
  fi
}

test_ai_manifest_paths_resolve
test_ai_manifest_paths_are_tracked
test_ai_manifest_paths_agree_across_twins
test_ai_ps1_documented_manifest_agrees
finish_tests
