#!/usr/bin/env bash
# Tests for the PowerShell here-string sub-check (run_here_string_policy, step 13).
#
# The PowerShell twin (13-repo-policy-data.ps1) reads the parse tree to decide
# which here-strings count as file content; the POSIX twin reads text through the
# here-string mode of repository-policy.awk. The two twins are the same policy on
# two hosts, so these cases pin the shared rule: 10 content lines by default, 25
# for a C# interop block, and nothing at all for a here-string that is neither
# interop nor written to disk. Each case drives the real sub-check through the
# real check-lib against a throwaway repo, so a rule that drifts from the twin
# fails here instead of only on the host that runs the other twin.
#
# Run with: bash tests/scripts/check-steps/13-here-string-parity-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
readonly REPO_ROOT

# The shared message prefix: both twins report a violation as "here-string with
# <n> content lines (limit 10)", so a case asserts a whole line built from it
# rather than a loose fragment.
readonly RULE_TEXT="here-string with"

# run_subcheck <fixture-repo> <out-file>: invoke the sub-check the way the runner
# does, with the context as its only argument, and print the exit status.
# WHY no -e: the sub-check reports each violation through error(), which returns
# 1 by design, so -e would abort the scan after the first finding and a
# multi-violation case could never see the second one. The runner sources the
# step without -e for the same reason.
run_subcheck() { # <fixture-repo> <out-file>
  local rc=0
  (
    bash -c '
      set -uo pipefail
      . "$1/src/scripts/checks/check-lib.sh"
      . "$1/src/scripts/checks/check-steps/13-repo-policy-data.sh"
      declare -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$2")
      run_here_string_policy _ctx
    ' _ "$REPO_ROOT" "$1"
  ) >"$2" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# emit_here_string <opener-line> <content-lines> <closer> [crlf]:
# write one here-string, its opener and its closing mark included.
emit_here_string() { # <opener> <count> <closer> <crlf>
  local _opener="$1" _count="$2" _closer="$3" _crlf="$4" _i=0 _eol=""
  [ "$_crlf" = "crlf" ] && _eol=$'\r'
  printf '%s%s\n' "$_opener" "$_eol"
  while [ "$_i" -lt "$_count" ]; do
    printf 'content line %d%s\n' "$_i" "$_eol"
    _i=$((_i + 1))
  done
  printf '%s%s\n' "$_closer" "$_eol"
}

# new_fixture <name>: a throwaway repo root holding a single .ps1, so nothing in
# the live tree can satisfy a case the fixture forgot.
new_fixture() { # <name>
  local _dir
  _dir="$(mktemp -d)"
  printf '%s/%s.ps1\n' "$_dir" "$1"
}

# assert_reports <name> <fixture-repo> <expected-substring>: the sub-check must
# fail and print EXPECTED. A case that only checked the exit status would pass on
# any unrelated failure in the step, so the message is asserted too.
assert_reports() { # <name> <fixture-repo> <expected>
  local _name="$1" _repo="$2" _expected="$3" _out rc
  _out="$(mktemp)"
  rc="$(run_subcheck "$_repo" "$_out")"
  if [ "$rc" -eq 1 ] && grep -qF -- "$_expected" "$_out"; then
    assert_pass "$_name"
  else
    assert_fail "$_name" "rc=$rc (expected 1) expected '$_expected'; output: $(tr '\n' '|' <"$_out")"
  fi
  rm -f "$_out"
  rm -rf "$_repo"
}

# assert_silent <name> <fixture-repo>: the sub-check must pass and report no
# violation. The pass message is asserted so a step that never reached the awk
# scan cannot look clean.
assert_silent() { # <name> <fixture-repo>
  local _name="$1" _repo="$2" _out rc
  _out="$(mktemp)"
  rc="$(run_subcheck "$_repo" "$_out")"
  if [ "$rc" -eq 0 ] && ! grep -qF -- "$RULE_TEXT" "$_out" && grep -qF 'here-string violations found' "$_out"; then
    assert_pass "$_name"
  else
    assert_fail "$_name" "rc=$rc (expected 0) output: $(tr '\n' '|' <"$_out")"
  fi
  rm -f "$_out"
  rm -rf "$_repo"
}

test_oversized_written_here_string_fails() {
  local file
  file="$(new_fixture oversized)"
  {
    emit_here_string 'Set-Content -Path out.txt -Value @"' 11 '"@' ""
  } >"$file"
  assert_reports "a here-string of 11 content lines written to disk fails" \
    "${file%/*}" "$RULE_TEXT 11 content lines (limit 10)"
}

test_here_string_within_limit_passes() {
  local file
  file="$(new_fixture within-limit)"
  {
    emit_here_string 'Set-Content -Path out.txt -Value @"' 9 '"@' ""
  } >"$file"
  assert_silent "a here-string of 9 content lines passes" "${file%/*}"
}

test_oversized_interop_block_fails() {
  local file
  file="$(new_fixture interop-over)"
  {
    emit_here_string 'Add-Type @"' 26 '"@' ""
  } >"$file"
  assert_reports "a C# interop block of 26 content lines fails the 25-line cap" \
    "${file%/*}" "$RULE_TEXT 26 content lines"
}

test_interop_block_within_cap_passes() {
  local file
  file="$(new_fixture interop-under)"
  {
    emit_here_string 'Add-Type @"' 24 '"@' ""
  } >"$file"
  assert_silent "a C# interop block of 24 content lines passes the 25-line cap" "${file%/*}"
}

test_here_string_not_written_to_disk_is_ignored() {
  local file
  file="$(new_fixture subprocess-text)"
  {
    # shellcheck disable=SC2016 # reason: the PowerShell variable is fixture text, not a shell expansion
    emit_here_string '$scriptText = @"' 12 '"@ | Write-Output' ""
  } >"$file"
  # The twin skips a here-string that is neither interop nor file content: the
  # text runs somewhere else, such as a subprocess driver.
  assert_silent "a 12-line here-string that is not file content is ignored" "${file%/*}"
}

test_pipeline_write_to_disk_counts_as_file_content() {
  local file
  file="$(new_fixture pipeline-write)"
  {
    # shellcheck disable=SC2016 # reason: the PowerShell variable is fixture text, not a shell expansion
    emit_here_string '$wrapper = @"' 11 '"@ | Set-Content -Path out.ps1 -NoNewline' ""
  } >"$file"
  assert_reports "the pipeline form into Set-Content counts as file content" \
    "${file%/*}" "$RULE_TEXT 11 content lines"
}

test_policy_citation_exempts_the_site() {
  local file
  file="$(new_fixture cited)"
  {
    printf '# check-suppress:embedded-content: fixture justification\n'
    emit_here_string 'Set-Content -Path out.txt -Value @"' 12 '"@' ""
  } >"$file"
  assert_silent "a policy citation above the here-string exempts the site" "${file%/*}"
}

test_two_here_strings_in_one_file_are_both_reported() {
  local file out rc
  file="$(new_fixture two-sites)"
  {
    emit_here_string 'Set-Content -Path a.txt -Value @"' 11 '"@' ""
    emit_here_string 'Set-Content -Path b.txt -Value @"' 12 '"@' ""
  } >"$file"
  out="$(mktemp)"
  rc="$(run_subcheck "${file%/*}" "$out")"
  if [ "$rc" -eq 1 ] &&
    grep -qF "$RULE_TEXT 11 content lines" "$out" &&
    grep -qF "$RULE_TEXT 12 content lines" "$out"; then
    assert_pass "two oversized here-strings in one file are both reported"
  else
    assert_fail "two oversized here-strings in one file are both reported" "rc=$rc output: $(tr '\n' '|' <"$out")"
  fi
  rm -f "$out"
  rm -rf "${file%/*}"
}

test_unclosed_here_string_is_not_counted() {
  local file
  file="$(new_fixture unclosed)"
  printf 'Set-Content -Path out.txt -Value @"\n' >"$file"
  printf 'content line\n' >>"$file"
  # An unclosed here-string is a PowerShell syntax error, which the lint step
  # reports; the twin skips a file it cannot parse and so does this scan.
  assert_silent "an unclosed here-string is left to the lint step" "${file%/*}"
}

test_crlf_here_string_is_counted() {
  local file
  file="$(new_fixture crlf)"
  emit_here_string 'Set-Content -Path out.txt -Value @"' 11 '"@' "crlf" >"$file"
  assert_reports "CRLF line endings do not hide a here-string body" \
    "${file%/*}" "$RULE_TEXT 11 content lines"
}

section 1 "the twin's thresholds"
test_oversized_written_here_string_fails
test_here_string_within_limit_passes
test_oversized_interop_block_fails
test_interop_block_within_cap_passes

section 2 "the twin's gate"
test_here_string_not_written_to_disk_is_ignored
test_pipeline_write_to_disk_counts_as_file_content
test_policy_citation_exempts_the_site

section 3 "per-file state"
test_two_here_strings_in_one_file_are_both_reported
test_unclosed_here_string_is_not_counted
test_crlf_here_string_is_counted

finish_tests
