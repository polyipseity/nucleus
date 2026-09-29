#!/usr/bin/env bash
# shellcheck shell=bash
# Test: activation tool resolution (check step 11, run_activation_tool_resolution).
#
# This sub-check reported zero violations on every file after
# services/camilladsp-deviceselect.sh, because the awk program's case_depth was
# never reset between files and a one-line `case ... esac` left it raised. These
# tests exercise the real function against fixture trees so a reintroduction of
# that blindness, or of the two-character command filter, fails here.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/11-repo-policy-grep.sh"

# shellcheck source=../../../src/scripts/checks/check-steps/11-repo-policy-grep.sh
. "$TEST_FILE" || exit 1

# Run the sub-check over a fixture tree and capture its combined output.
# $1: fixture root. Sets _out to the check's stdout+stderr.
run_resolution() {
  local _root="$1"
  local -A _ctx=([HAS_ARGS]=false [REPO_ROOT]="$_root")
  _out=$(
    cd "$_root" || return 1
    run_activation_tool_resolution _ctx 2>&1
  )
}

# A minimal activation dir holding the script body passed as $1.
make_fixture() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/src/scripts/configs" "$_root/src/scripts/services"
  printf '%s\n' "#!/usr/bin/env bash" "set -eu" >"$_root/src/scripts/configs/probe.sh"
  printf '%s\n' "$1" >>"$_root/src/scripts/configs/probe.sh"
  printf '%s\n' "$_root"
}

fail() {
  echo "FAIL: $1"
  [ -n "${2-}" ] && echo "$2"
  return 1
}

# Does the report name this exact command? Quotes inside a case pattern are
# stripped by bash, so *'ip'* is just *ip* and would also match a random mktemp
# path in the check's own output. The needle is built in a variable and expanded
# quoted so the match is against the violation text alone.
reported() {
  case "$_out" in
  *"bare external command '$1'"*) return 0 ;;
  *) return 1 ;;
  esac
}

# A bare two-character command must be reported. This is the assertion that
# fails if the length filter returns, and it is meaningless unless the scan
# actually reaches the file.
test_short_command_is_reported() {
  local _root _rc
  _root=$(make_fixture '  ip link show wlan0')
  run_resolution "$_root"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "a bare two-character command was not reported" "$_out"
    return 1
  fi
  if reported ip; then
    return 0
  fi
  fail "expected ip to be reported" "$_out"
  return 1
}

# Two runs over the same tree must agree. The candidate list is built by find,
# whose sibling order is filesystem-dependent, so without an explicit sort the
# scanned set — and therefore the report — is not reproducible.
test_scan_is_deterministic() {
  local _root _first _second
  _root=$(make_fixture '  ip link show wlan0')
  run_resolution "$_root"
  _first="$_out"
  run_resolution "$_root"
  _second="$_out"
  rm -rf "$_root"
  if [ -z "$_first" ]; then
    fail "determinism compared two empty reports" "$_out"
    return 1
  fi
  if [ "$_first" != "$_second" ]; then
    fail "two runs over the same tree disagreed" "$_first"
    return 1
  fi
  return 0
}

# A one-line `case ... esac` must not leave case_depth raised for the rest of
# the file. The bare command sits after the case, so a leaked depth hides it.
test_one_line_case_does_not_blind() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/src/scripts/configs"
  {
    printf '%s\n' "#!/usr/bin/env bash" "set -eu"
    # shellcheck disable=SC2016 # reason: fixture body must not be expanded by the test shell
    printf '%s\n' '  case "$_x" in a) _x=0 ;; esac'
    printf '%s\n' '  ip link show wlan0'
  } >"$_root/src/scripts/configs/probe.sh"
  run_resolution "$_root"
  rm -rf "$_root"
  if reported ip; then
    return 0
  fi
  fail "a one-line case blinded the rest of its own file" "$_out"
  return 1
}

# Per-file state must reset. The first script ends with a multi-line `case`
# whose esac is absent, so the parser leaves case_depth raised at EOF. With no
# FNR == 1 reset the second script is skipped wholesale by the case_depth rule
# — the same mechanism as the original blind spot. The leaking file must sort
# first, and candidates are sorted by path, so it lives in agents/, which
# precedes configs/.
test_state_resets_between_files() {
  local _root _rc
  _root=$(mktemp -d)
  mkdir -p "$_root/src/scripts/agents" "$_root/src/scripts/configs"
  {
    # shellcheck disable=SC2016 # reason: the fixture body must reach the file unexpanded
    printf '%s\n' "#!/usr/bin/env bash" 'case "$_y" in' "  a) : ;;"
  } >"$_root/src/scripts/agents/aaa-leak.sh"
  printf '%s\n' "#!/usr/bin/env bash" "  ip link show wlan0" \
    >"$_root/src/scripts/configs/probe.sh"
  run_resolution "$_root"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "a bare command after an unclosed case was not reported" "$_out"
    return 1
  fi
  if reported ip; then
    return 0
  fi
  fail "state leaked between files" "$_out"
  return 1
}

# The body of an embedded awk program is program text. Its keywords must not be
# read as shell commands.
test_embedded_awk_body_is_not_scanned() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/src/scripts/configs"
  cat >"$_root/src/scripts/configs/probe.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -eu
some_bare_tool /dev/null
"$_t_awk_bin" '
  BEGIN { section = "" }
  /^[[:space:]]*([;#]|$)/ { next }
  pos = index($0, "=")
  sub(/^[^=]*/, "", $0)
  gsub(/[[:space:]]/, "", $0)
  print section
' "$_in"
FIXTURE
  run_resolution "$_root"
  rm -rf "$_root"
  # some_bare_tool is a real violation, so an empty report would mean the scan
  # found nothing at all rather than that the awk keywords were skipped.
  for _tok in sub gsub print pos; do
    if reported "$_tok"; then
      fail "embedded awk body was scanned ($_tok)" "$_out"
      return 1
    fi
  done
  if reported some_bare_tool; then
    return 0
  fi
  fail "the positive control was not reported, so the absence is not evidence" "$_out"
  return 1
}

# A line continued with a backslash is one command. The continuation must not be
# read on its own, where its leading path would be stripped to a basename.
test_continuation_line_is_not_a_command() {
  local _root
  # shellcheck disable=SC1003 # reason: the trailing backslash is fixture content, not a line continuation
  _root=$(make_fixture '  some_tool arg1 \')
  printf '%s\n' '    2>/dev/null || warn "no output"' \
    >>"$_root/src/scripts/configs/probe.sh"
  run_resolution "$_root"
  rm -rf "$_root"
  if reported null; then
    fail "continuation line was read as a command" "$_out"
    return 1
  fi
  if reported some_tool; then
    return 0
  fi
  fail "the positive control was not reported, so the absence is not evidence" "$_out"
  return 1
}

# The android fake-wifi guest scripts are excluded from the full-repo scan.
# The exclusion is a glob; a `$`-anchored prefix matches none of them.
test_guest_scripts_are_excluded() {
  local _root
  _root=$(make_fixture '  ip link show wlan0')
  printf '%s\n' "#!/usr/bin/env bash" "  ip link show wlan0" \
    >"$_root/src/scripts/services/android-fake-wifi-guest-setup.sh"
  run_resolution "$_root"
  rm -rf "$_root"
  # probe.sh is outside the exclusion, so a report that still names the bare
  # command proves the scan ran and the exclusion is what suppressed the guest.
  case "$_out" in
  *android-fake-wifi-guest-setup*)
    fail "excluded script was reported" "$_out"
    return 1
    ;;
  esac
  if reported ip; then
    return 0
  fi
  fail "the positive control was not reported, so the absence is not evidence" "$_out"
  return 1
}

failures=0
for test in \
  test_short_command_is_reported \
  test_scan_is_deterministic \
  test_one_line_case_does_not_blind \
  test_state_resets_between_files \
  test_embedded_awk_body_is_not_scanned \
  test_continuation_line_is_not_a_command \
  test_guest_scripts_are_excluded; do
  if ! "$test"; then
    echo "FAIL: $test"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures activation tool resolution test(s) failed"
  exit 1
fi
echo "PASS: activation tool resolution"

# ---------------------------------------------------------------------------
# srt wrapper invariants (run_srt_wrapper_invariants)
#
# srt parses its own options wherever they appear, so a wrapper that forwards
# arguments without `--` loses them: `pi --help` prints srt's usage and
# `pi -c <arg>` drops both arguments silently. The scan is driven with explicit
# positional files (HAS_ARGS=true) so it never depends on the gitignore filter
# being available inside a temporary fixture tree.
# ---------------------------------------------------------------------------

# Run the srt sub-check over one or more files and capture its combined output.
# $@: file paths, relative to the repository root.
run_srt_scan() {
  local _file
  for _file in "$@"; do
    [ -f "$_file" ] || return 1
  done
  local -A _srt_ctx=([HAS_ARGS]=true [REPO_ROOT]="$REPO_ROOT")
  _out=$(
    cd "$REPO_ROOT" || return 1
    run_srt_wrapper_invariants _srt_ctx "$@" 2>&1
  )
}

# Does the report blame this file? Matched on the basename plus the trailing
# "forwards the user's arguments" text, so a match can only come from the
# violation line and not from the fixture path echoed elsewhere.
srt_blames() {
  case "$_out" in
  *"$(basename -- "$1"):"*"forwards the user's arguments"*) return 0 ;;
  *) return 1 ;;
  esac
}

srt_fixture() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/src/scripts/shell"
  printf '%s\n' "$@" >"$_root/src/scripts/shell/probe.sh"
  printf '%s\n' "$_root/src/scripts/shell/probe.sh"
}

# The defect itself: a wrapper forwarding without the marker must be reported.
# The positive control matters more than the negative half, because a scan that
# reads nothing reports nothing and would pass a naive "no violation" assertion.
test_srt_unseparated_wrapper_is_reported() {
  local _probe _rc
  _probe=$(srt_fixture 'srt command pi "$@"')
  run_srt_scan "$_probe"
  _rc=$?
  rm -rf "$(dirname -- "$(dirname -- "$_probe")")"
  if [ "$_rc" -eq 0 ]; then
    fail "a wrapper without the separator was not reported" "$_out"
    return 1
  fi
  if srt_blames "$_probe"; then
    return 0
  fi
  fail "the report does not name the offending file" "$_out"
  return 1
}

# An argument that merely starts with a dash is still forwarded verbatim, so
# `pi -p x` has to be reported. Without the word-boundary tail on the exonerating
# pattern this line would pass as if `--` were present.
test_srt_leading_dash_argument_is_reported() {
  local _probe _rc
  _probe=$(srt_fixture 'srt command pi -p x')
  run_srt_scan "$_probe"
  _rc=$?
  rm -rf "$(dirname -- "$(dirname -- "$_probe")")"
  if [ "$_rc" -ne 0 ] && srt_blames "$_probe"; then
    return 0
  fi
  fail "a wrapper whose first forwarded argument is a flag was not reported" "$_out"
  return 1
}

# The fixed shape must pass, otherwise the rule would reject the repository's own
# wrappers. Asserted on both real host wrappers, not on a copy of them.
test_srt_separated_wrapper_is_accepted() {
  local _rc
  run_srt_scan src/scripts/shell/init.zsh src/scripts/shell/profile.ps1
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    fail "the shipped wrappers were reported" "$_out"
    return 1
  fi
  return 0
}

# Neither a comment quoting the invocation nor the `srt -c '<string>'` form is a
# violation: the string sits behind -c as one argument and exposes no per-argument
# flag for srt's parser to steal. The unseparated line alongside them is the
# positive control, so an exclusion that suppressed everything would still fail.
test_srt_comment_and_c_form_are_ignored() {
  local _probe _rc
  _probe=$(srt_fixture '# example: srt command pi "$@"' "srt -c 'pi --help'" 'srt command pi -- "$@"' 'srt command pi --help')
  run_srt_scan "$_probe"
  _rc=$?
  rm -rf "$(dirname -- "$(dirname -- "$_probe")")"
  if [ "$_rc" -eq 0 ]; then
    fail "the scan reported nothing, so the exclusions were not exercised" "$_out"
    return 1
  fi
  # Exactly the last line is the violation.
  if [ "$(grep -c "forwards the user's arguments" <<<"$_out")" -ne 1 ]; then
    fail "expected exactly one violation, got:" "$_out"
    return 1
  fi
  return 0
}

# The step files carry the rule's own wording. Scanning them must find nothing:
# that is what lets the scan cover its own source without an exclusion list.
test_srt_step_files_are_not_self_reported() {
  local _rc
  run_srt_scan \
    src/scripts/checks/check-steps/11-repo-policy-grep.sh \
    src/scripts/checks/check-steps/11-repo-policy-grep.ps1
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    fail "the check reported its own step files" "$_out"
    return 1
  fi
  return 0
}

srt_failures=0
for test in \
  test_srt_unseparated_wrapper_is_reported \
  test_srt_leading_dash_argument_is_reported \
  test_srt_separated_wrapper_is_accepted \
  test_srt_comment_and_c_form_are_ignored \
  test_srt_step_files_are_not_self_reported; do
  if ! "$test"; then
    echo "FAIL: $test"
    srt_failures=$((srt_failures + 1))
  fi
done

if [ "$srt_failures" -ne 0 ]; then
  echo "FAIL: $srt_failures srt wrapper invariant test(s) failed"
  exit 1
fi
echo "PASS: srt wrapper invariants"
