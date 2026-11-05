#!/usr/bin/env bash
# WHY: the runner prints `no error record` when `BeforeAll` throws, so a
# suite-setup failure is invisible; this suite pins the fix.
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
STEP_FILE="$REPO_ROOT/src/scripts/tests/test-steps/06-windows-pester.ps1"

test_block_failure_reports_blockfailed_line() {
  local _tmp _runner _fixture _out _exit=0
  _tmp=$(mktemp -d)
  _runner="$_tmp/runner.ps1"
  _fixture="$_tmp/fixture.Tests.ps1"
  # Extract the real runner from the step file, never reimplement it here.
  # CR is stripped first: .gitattributes keeps *.ps1 CRLF, so ^'@$ never matches
  # otherwise; the second sed drops the here-string delimiters so only the
  # program body remains and pwsh executes it.
  tr -d '\r' <"$STEP_FILE" | sed -n "/runnerSource = @'/,/^'@\$/p" | sed '1d;$d' >"$_runner"
  if [ ! -s "$_runner" ]; then
    assert_fail "runner extraction from 06-windows-pester.ps1" "extraction produced an empty $_runner"
  else
    cat >"$_fixture" <<'EOF'
Describe 'block failure fixture' {
  BeforeAll { throw 'BLOCKFIXTURE-MESSAGE' }
  It 'never runs' { $true | Should -Be $true }
}
EOF
    _out=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$_runner" -SuitePath "$_fixture" 2>&1) || _exit=$?
    if [ "$_exit" -ne 1 ]; then
      assert_fail "a BeforeAll throw prints nucleus-pester blockfailed with the thrown message" "exit=$_exit output=[$_out]"
    elif ! printf '%s\n' "$_out" | grep -qF 'blockfailed:'; then
      assert_fail "a BeforeAll throw prints nucleus-pester blockfailed with the thrown message" "no blockfailed: line, exit=$_exit output=[$_out]"
    elif ! printf '%s\n' "$_out" | grep -qF 'BLOCKFIXTURE-MESSAGE'; then
      assert_fail "a BeforeAll throw prints nucleus-pester blockfailed with the thrown message" "thrown message missing, exit=$_exit output=[$_out]"
    else
      assert_pass "a BeforeAll throw prints nucleus-pester blockfailed with the thrown message"
    fi
  fi
  # Explicit removal at the end instead of an EXIT trap: _tmp is local to this
  # function, so a trap would expand it after the function returns and remove nothing.
  rm -rf "$_tmp"
}

test_block_failure_reports_blockfailed_line
finish_tests
