#!/usr/bin/env bash
# shellcheck shell=bash
# Test: repo-policy-grep (check step 11) carries no A1 exclusion self-prune.
#
# The A1 exclusion list used to name check.sh, check.ps1 and shell.nix, and the
# self-prune that policed it was guarded by `[ -f "$_excluded" ]`. None of the
# three resolved at the probed path, so the guard short-circuited and the T2
# policy could never fire for them: a stale entry was undetectable by
# construction. The list is gone and the self-prune with it.
#
# WHY this asserts absence rather than evaluating a guard: the self-prune was
# removed, so there is no control flow left to execute. A test that extracted
# and ran the block would evaluate nothing and pass for any input, the
# non-discriminating-assertion shape this project has produced repeatedly.
# Pinning the absence is the only assertion with a reachable failure mode.
#
# WHY the exclusion scan is scoped by function rather than by line number: the
# activation-tool scan (run_activation_tool_resolution) excludes check.sh for an
# unrelated reason and is registered as A13. Anchoring to line numbers would let
# an edit above them turn a true negative into a false failure.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
STEP_SH="$REPO_ROOT/src/scripts/checks/check-steps/11-repo-policy-grep.sh"
STEP_PS1="$REPO_ROOT/src/scripts/checks/check-steps/11-repo-policy-grep.ps1"

pass_count=0
fail_count=0

assert_pass() {
  printf 'PASS %s\n' "$1"
  pass_count=$((pass_count + 1))
}

assert_fail() {
  printf 'FAIL %s : %s\n' "$1" "$2"
  fail_count=$((fail_count + 1))
}

# extract_pme_sh: the POSIX package-manager enforcement function, from its
# opening brace to the line that closes it. The self-prune lived inside this
# function and nowhere else.
extract_pme_sh() {
  awk '/^run_package_manager_enforcement\(\) \{$/ {grab=1} grab {print} grab && /^\}$/ {exit}' "$STEP_SH"
}

# extract_pme_ps1: the PowerShell package-manager section, from its header to
# the next section header.
extract_pme_ps1() {
  awk '/# --- Package manager enforcement ---/ {grab=1} grab {print} grab && /# --- Suppression audit ---/ {exit}' "$STEP_PS1"
}

removed='check\.sh|check\.ps1|shell\.nix'

# 1. Neither twin may reintroduce a self-prune over the exclusion list. The
#    inert guard is the defect being kept out; a future exclusion that arrives
#    with its own guard is fine, but the empty-loop shape that shipped is not.
sh_prune="$(extract_pme_sh | grep -nE 'for _excluded in|does not exist: .*remove it from the exclusion list|stale exclusion:' || true)"
# shellcheck disable=SC2016 # reason: the pattern matches literal PowerShell source in the twin, so $ef must not expand in bash
ps1_prune="$(extract_pme_ps1 | grep -nE 'foreach \(\$ef in|does not exist: .*remove it from the exclusion list|stale exclusion:' || true)"
if [ -z "$sh_prune" ] && [ -z "$ps1_prune" ]; then
  assert_pass 'neither twin reintroduces an A1 self-prune over the exclusion list'
else
  assert_fail 'neither twin reintroduces an A1 self-prune over the exclusion list' "sh: ${sh_prune:-none} | ps1: ${ps1_prune:-none}"
fi

# 2. The removed names must not reappear as exclusion entries in the
#    package-manager function. check.sh is deliberately absent from this
#    pattern: the activation-tool scan excludes it under A13, and scoping by
#    function is what keeps that legitimate exclusion out of the comparison.
sh_hits="$(extract_pme_sh | grep -nE "$removed" || true)"
ps1_hits="$(extract_pme_ps1 | grep -nE "$removed" || true)"
if [ -z "$sh_hits" ] && [ -z "$ps1_hits" ]; then
  assert_pass 'the removed A1 names appear at no exclusion site in the package-manager function'
else
  assert_fail 'the removed A1 names appear at no exclusion site in the package-manager function' "sh: ${sh_hits:-none} | ps1: ${ps1_hits:-none}"
fi

# 3. The function-scoped extraction must actually be reading the function, or
#    cases 1 and 2 pass on empty input and prove nothing. A function that
#    vanished would make both greps above trivially empty.
sh_len="$(extract_pme_sh | wc -l | tr -d ' ')"
ps1_len="$(extract_pme_ps1 | wc -l | tr -d ' ')"
if [ "$sh_len" -gt 10 ] && [ "$ps1_len" -gt 10 ]; then
  assert_pass "the extraction scopes are non-empty (sh ${sh_len} lines, ps1 ${ps1_len} lines)"
else
  assert_fail 'the extraction scopes are non-empty' "sh ${sh_len} lines, ps1 ${ps1_len} lines"
fi

# 4. This file must not itself trip the check it guards. The PowerShell twin
#    scans tests/ and filters only the six step filenames, so a literal here
#    would fail the Windows job. The check is byte-level on this file's own
#    contents, which is the same property the reviewer found broken.
#
# WHY the pattern is assembled from fragments: writing the literal into this
# grep would make the file its own violation, which is precisely the failure
# this case exists to catch. The fragments are concatenated at runtime so the
# contiguous string never appears in this file's bytes.
_pm='pi''p'
_act='ins''tall'
_literal="(^|[^a-z])$_pm $_act([^-]|\$)"
if grep -qE "$_literal" "$0"; then
  assert_fail 'this test file carries no bare package-manager install literal' 'a literal that step 11 would report'
else
  assert_pass 'this test file carries no bare package-manager install literal'
fi

printf '\nTOTAL %s passed, %s failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
