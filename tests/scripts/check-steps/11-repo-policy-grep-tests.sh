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
# scanned set, and therefore the report, is not reproducible.
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
#, the same mechanism as the original blind spot. The leaking file must sort
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
# PowerShell suppression audit (run_suppression_audit, the .ps1 half)
#
# The PowerShell twin audits .ps1 for unannotated suppressions. Without the
# mirror a bad suppression is only ever caught on the Windows host, so these
# tests drive the POSIX rule over .ps1 fixtures and check it accepts exactly
# what the twin accepts: a comment line, an annotation on the line itself, an
# annotation on the line above, and the tests/ exemption for the four patterns
# that carry it.
#
# The scan is driven with explicit positional files (HAS_ARGS=true) so it never
# depends on the gitignore filter being available inside a temporary fixture
# tree, the same reason the srt section above does it.
# ---------------------------------------------------------------------------

PS1_FILES=()
SH_FILES=()
NIX_FILES=()

# Run the audit over the given .ps1 files and capture its combined output.
run_ps1_supp_scan() {
  PS1_FILES=("$@")
  local -A _ps1_ctx=(
    [HAS_ARGS]=true
    [REPO_ROOT]="$REPO_ROOT"
    [SH_FILES]="SH_FILES"
    [PS1_FILES]="PS1_FILES"
    [NIX_FILES]="NIX_FILES"
  )
  _out=$(
    cd "$REPO_ROOT" || return 1
    run_suppression_audit _ps1_ctx 2>&1
  )
}

# Write a .ps1 fixture holding the given lines and print its path.
# $1: directory to create under a fresh temp root, remaining args: file lines.
ps1_fixture() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/$1"
  printf '%s\n' "${@:2}" >"$_root/$1/probe.ps1"
  printf '%s\n' "$_root/$1/probe.ps1"
}

fixture_root() {
  printf '%s\n' "$(dirname -- "$(dirname -- "$1")")"
}

# Does the report blame this file, line and pattern? Matched on the basename
# plus the reported line and label, so a match can only come from the
# violation line and not from the fixture path echoed elsewhere.
ps1_blames() {
  case "$_out" in
  *"$(basename -- "$1"):$2 ($3)"*) return 0 ;;
  *) return 1 ;;
  esac
}

# The defect itself. Without this the acceptance tests below would pass against
# a scan that reads nothing.
test_ps1_undocumented_suppression_is_reported() {
  local _probe _root _rc
  _probe=$(ps1_fixture src "\$a = Get-Item 'p' -ErrorAction SilentlyContinue")
  _root=$(fixture_root "$_probe")
  run_ps1_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "an unannotated PowerShell suppression was not reported" "$_out"
    return 1
  fi
  if ps1_blames "$_probe" 1 '-ErrorAction SilentlyContinue'; then
    return 0
  fi
  fail "the report does not name the offending file and line" "$_out"
  return 1
}

# The documented form: the check id on the line itself.
test_ps1_same_line_annotation_documents() {
  local _probe _root _rc
  _probe=$(ps1_fixture src "# check-suppress:suppression_doc: probe; the null check below handles it" "\$a = Get-Item 'p' -ErrorAction SilentlyContinue # check-suppress:suppression_doc: probe; the null check below handles it")
  _root=$(fixture_root "$_probe")
  run_ps1_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -ne 0 ]; then
    fail "an annotation on the same line was not accepted" "$_out"
    return 1
  fi
  return 0
}

# The annotation on the line above is the form the shipped scripts use, and the
# form a stricter rule than the twin's would reject.
test_ps1_preceding_line_annotation_documents() {
  local _probe _root _rc
  _probe=$(ps1_fixture src "# check-suppress:suppression_doc: probe; the null check below handles it" "\$a = Get-Item 'p' -ErrorAction SilentlyContinue")
  _root=$(fixture_root "$_probe")
  run_ps1_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -ne 0 ]; then
    fail "an annotation on the preceding line was not accepted" "$_out"
    return 1
  fi
  return 0
}

# A comment that names the pattern explains it and is not a violation. The
# shipped Invoke-ScoopSetup.ps1 has this exact shape, so a rule that scanned
# comment lines would report the repository's own file.
test_ps1_comment_line_is_not_a_violation() {
  local _rc
  run_ps1_supp_scan src/platforms/Windows/modules/setup/Invoke-ScoopSetup.ps1
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    fail "a comment naming the pattern was reported" "$_out"
    return 1
  fi
  return 0
}

# No annotation documents this one: it discards a result by piping it away, so
# the only fix is to not do it. The annotation on the line is the positive
# control that the scan read the file.
test_ps1_annotated_out_null_is_still_reported() {
  local _probe _root _rc
  _probe=$(ps1_fixture src "Get-Item 'z' | Out-Null # check-suppress:suppression_doc: discarded")
  _root=$(fixture_root "$_probe")
  run_ps1_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "an annotated '| Out-Null' was not reported" "$_out"
    return 1
  fi
  if ps1_blames "$_probe" 1 '| Out-Null'; then
    return 0
  fi
  fail "the report does not name the '| Out-Null' line" "$_out"
  return 1
}

# The suppression family is not enforced under tests/. Four patterns carry that
# exemption and three do not, so the same unannotated fixture must report only
# the three.
test_ps1_tests_directory_exemption() {
  local _probe _root _rc _reported
  _probe=$(ps1_fixture tests "\$a = Get-Item 'p' -ErrorAction SilentlyContinue" "\$b = & cmd /c ver 2>\$null" "\$null = Get-Item 'r'" "[void](Get-Item 'u')" "try { Get-Item 's' } catch {}" "Get-Item 'z' | Out-Null")
  _root=$(fixture_root "$_probe")
  run_ps1_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "the tests/ scan reported nothing, so the exemptions were not exercised" "$_out"
    return 1
  fi
  _reported=$(grep -c "probe.ps1:" <<<"$_out")
  if [ "$_reported" -ne 2 ]; then
    fail "expected 2 reported lines in tests/, got $_reported" "$_out"
    return 1
  fi
  if ps1_blames "$_probe" 5 'empty catch {}' && ps1_blames "$_probe" 6 '| Out-Null'; then
    return 0
  fi
  fail "the patterns without a tests/ exemption were not reported" "$_out"
  return 1
}

# The step files carry the literal pattern text of this scan, so they are
# excluded. The unannotated probe alongside them is the control: a scan that
# reported nothing at all would otherwise pass.
test_ps1_step_files_are_not_self_reported() {
  local _probe _root
  _probe=$(ps1_fixture src "\$a = Get-Item 'p' -ErrorAction SilentlyContinue")
  _root=$(fixture_root "$_probe")
  run_ps1_supp_scan \
    src/scripts/checks/check-steps/11-repo-policy-grep.ps1 \
    src/scripts/checks/check-steps/12-repo-policy-pattern.ps1 \
    src/scripts/checks/check-steps/13-repo-policy-data.ps1 \
    "$_probe"
  rm -rf "$_root"
  if ! ps1_blames "$_probe" 1 '-ErrorAction SilentlyContinue'; then
    fail "the positive control was not reported, so the absence is not evidence" "$_out"
    return 1
  fi
  case "$_out" in
  *11-repo-policy-grep.ps1* | *12-repo-policy-pattern.ps1* | *13-repo-policy-data.ps1*)
    fail "an excluded step file was reported" "$_out"
    return 1
    ;;
  esac
  return 0
}

ps1_failures=0
for test in \
  test_ps1_undocumented_suppression_is_reported \
  test_ps1_same_line_annotation_documents \
  test_ps1_preceding_line_annotation_documents \
  test_ps1_comment_line_is_not_a_violation \
  test_ps1_annotated_out_null_is_still_reported \
  test_ps1_tests_directory_exemption \
  test_ps1_step_files_are_not_self_reported; do
  if ! "$test"; then
    echo "FAIL: $test"
    ps1_failures=$((ps1_failures + 1))
  fi
done

if [ "$ps1_failures" -ne 0 ]; then
  echo "FAIL: $ps1_failures PowerShell suppression audit test(s) failed"
  exit 1
fi
echo "PASS: PowerShell suppression audit"

# ---------------------------------------------------------------------------
# POSIX suppression audit (run_suppression_audit, the .sh/.nix half)
#
# The shell and Nix half is not the PowerShell half: a shellcheck directive with
# no reason, or an annotation with an unregistered id, prints the offending line
# so it can be read straight out of the CI log, and a bare `|| true` prints its
# pattern label before the line. Both come out of one pass over the whole file
# list, so these tests drive the real function through one call per fixture set
# and pin the exact file:line text of every shape.
# ---------------------------------------------------------------------------

# Write a fixture file under a fresh temp root and print its path.
# $1: path under that root (e.g. src/probe.sh), remaining args: the file's lines.
supp_fixture() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/$(dirname -- "$1")"
  printf '%s\n' "${@:2}" >"$_root/$1"
  printf '%s\n' "$_root/$1"
}

# Run the audit over the given fixtures and capture its combined output.
# The half a fixture belongs to follows from its extension, which is what the
# audit dispatches on, so one call covers shell, Nix and PowerShell together.
run_supp_scan() {
  SH_FILES=()
  NIX_FILES=()
  PS1_FILES=()
  CACHED_NIX_FILES=()
  CACHED_SHELL_FILES=()
  local _f
  for _f in "$@"; do
    case "$_f" in
    *.sh) SH_FILES+=("$_f") ;;
    *.nix) NIX_FILES+=("$_f") ;;
    *.ps1) PS1_FILES+=("$_f") ;;
    esac
  done
  local -A _supp_ctx=(
    [HAS_ARGS]=true
    [REPO_ROOT]="$REPO_ROOT"
    [SH_FILES]="SH_FILES"
    [PS1_FILES]="PS1_FILES"
    [NIX_FILES]="NIX_FILES"
    [CACHED_NIX_FILES]="CACHED_NIX_FILES"
    [CACHED_SHELL_FILES]="CACHED_SHELL_FILES"
  )
  _out=$(
    cd "$REPO_ROOT" || return 1
    run_suppression_audit _supp_ctx 2>&1
  )
}

# Does the report carry this complete message line?
supp_reports() {
  case "$_out" in
  *"$1"*) return 0 ;;
  *) return 1 ;;
  esac
}

# An "accepted" case proves nothing on its own: a scan that reads no file also
# reports nothing. Every accepted fixture therefore shares its call with a
# control that must be reported, and nothing may be reported from the accepted
# one.
# $1: accepted fixture path, $2: the control's complete expected report line.
supp_only_control_reported() {
  local _accepted="$1" _expected="$2" _reported
  _reported=$(printf '%s\n' "$_out" | grep -c 'undoc_supp:')
  if [ "$_reported" -ne 1 ] || ! supp_reports "$_expected"; then
    fail "expected only the control to be reported, got $_reported" "$_out"
    return 1
  fi
  case "$_out" in
  *"$_accepted:"*)
    fail "the accepted fixture was reported" "$_out"
    return 1
    ;;
  esac
  return 0
}

# A shellcheck directive with no reason beside it is the shape the annotation
# audit exists for. The message repeats the line, so this pins it whole.
test_posix_unannotated_shellcheck_disable_is_reported() {
  local _probe _root _rc
  _probe=$(supp_fixture src/probe.sh "#!/usr/bin/env bash" "# shellcheck disable=SC2086") # check-suppress:suppression_doc: fixture text -- the pattern under test
  _root=$(fixture_root "$_probe")
  run_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "an unannotated shellcheck disable was not reported" "$_out"
    return 1
  fi
  if supp_reports "undoc_supp:$_probe:2:# shellcheck disable=SC2086"; then # check-suppress:suppression_doc: expected report -- the audit echoes the line
    return 0
  fi
  fail "the report does not carry the offending line" "$_out"
  return 1
}

# The documented form: `reason:` on the same line. The undocumented directive in
# the same call is the control: it proves the annotation audit ran, and a dropped
# negative filter reports the accepted fixture alongside it.
test_posix_documented_shellcheck_disable_is_accepted() {
  local _probe _control
  _probe=$(supp_fixture src/probe.sh "#!/usr/bin/env bash" "# shellcheck disable=SC2086 # reason: probe")
  _control=$(supp_fixture src/control.sh "#!/usr/bin/env bash" "# shellcheck disable=SC2086") # check-suppress:suppression_doc: fixture text -- the control's pattern
  run_supp_scan "$_probe" "$_control"
  rm -rf "$(fixture_root "$_probe")" "$(fixture_root "$_control")"
  if ! supp_only_control_reported "$_probe" "undoc_supp:$_control:2:# shellcheck disable=SC2086"; then # check-suppress:suppression_doc: expected report -- the audit echoes the line
    return 1
  fi
  return 0
}

# A bare `|| true` prints its label, then the line as written (leading
# indentation included), which is why the expected string is exact.
test_posix_bare_or_true_is_reported() {
  local _probe _root _rc
  _probe=$(supp_fixture src/probe.sh "#!/usr/bin/env bash" "  probe_cmd || true")
  _root=$(fixture_root "$_probe")
  run_supp_scan "$_probe"
  _rc=$?
  rm -rf "$_root"
  if [ "$_rc" -eq 0 ]; then
    fail "a bare '|| true' was not reported" "$_out"
    return 1
  fi
  if supp_reports "undoc_supp:$_probe:2:|| true:   probe_cmd || true"; then
    return 0
  fi
  fail "the report does not carry the label and the line" "$_out"
  return 1
}

# The annotation above the line documents it, the same acceptance the
# PowerShell half applies and the form the shipped scripts use. The undocumented
# `|| true` in the same call is the control.
test_posix_documented_or_true_is_accepted() {
  local _probe _control
  _probe=$(supp_fixture src/probe.sh \
    "#!/usr/bin/env bash" \
    "# check-suppress:suppression_doc: probe; the caller inspects the status" \
    "  probe_cmd || true")
  _control=$(supp_fixture src/control.sh "#!/usr/bin/env bash" "  other_cmd || true")
  run_supp_scan "$_probe" "$_control"
  rm -rf "$(fixture_root "$_probe")" "$(fixture_root "$_control")"
  if ! supp_only_control_reported "$_probe" "undoc_supp:$_control:2:|| true:   other_cmd || true"; then
    return 1
  fi
  return 0
}

# Only `|| true` carries the tests/ exemption; the annotation audit does not.
# The .nix control outside tests/ is what keeps this from passing against a
# scan that reported nothing, and it also proves a Nix file reaches the rule.
test_posix_or_true_tests_directory_exemption() {
  local _exempt _control _root _reported
  _exempt=$(supp_fixture tests/probe.sh "#!/usr/bin/env bash" "  probe_cmd || true")
  _control=$(supp_fixture src/probe.nix "  bad = probe || true;")
  _root=$(fixture_root "$_control")
  run_supp_scan "$_exempt" "$_control"
  _reported=$(printf '%s\n' "$_out" | grep -c 'undoc_supp:')
  rm -rf "$_root" "$(fixture_root "$_exempt")"
  if [ "$_reported" -ne 1 ]; then
    fail "expected exactly the control to be reported, got $_reported" "$_out"
    return 1
  fi
  if ! supp_reports "undoc_supp:$_control:1:|| true:   bad = probe || true;"; then
    fail "the control was not reported" "$_out"
    return 1
  fi
  case "$_out" in
  *"probe.sh"*)
    fail "the tests/ fixture was reported" "$_out"
    return 1
    ;;
  esac
  return 0
}

# Per-file state must not leak. The first file ends on an annotation line, so a
# program that carried `prev` into the next file would read the second file's
# line 1 as documented and report nothing. Two mechanisms prevent that and each
# is sufficient alone: the `FNR > 1` guard on the prev check, and the reset in
# the FNR == 1 block. Removing either one leaves this case green, because the
# other still holds; removing both turns it red.
test_posix_annotation_does_not_cross_files() {
  local _first _second _reported
  _first=$(supp_fixture src/first.sh "#!/usr/bin/env bash" "# check-suppress:suppression_doc: probe; documents this file only")
  _second=$(supp_fixture src/second.sh "  probe_cmd || true")
  run_supp_scan "$_first" "$_second"
  _reported=$(printf '%s\n' "$_out" | grep -c 'undoc_supp:')
  rm -rf "$(fixture_root "$_first")" "$(fixture_root "$_second")"
  if [ "$_reported" -ne 1 ]; then
    fail "expected the second file's line 1 to be reported, got $_reported" "$_out"
    return 1
  fi
  if ! supp_reports "undoc_supp:$_second:1:|| true:   probe_cmd || true"; then
    fail "the line 1 violation was not reported" "$_out"
    return 1
  fi
  case "$_out" in
  *"$_first:"*)
    fail "the annotation-only file was reported" "$_out"
    return 1
    ;;
  esac
  return 0
}

# One call, both halves. Each family keeps its own message shape and its own
# pattern list, so a program that applied one list to every file loses four of
# these five lines.
test_posix_mixed_family_scan_reports_each_shape() {
  local _ps1 _sh _root _sh_root _ps1_lines _sh_lines
  # shellcheck disable=SC2016 # reason: fixture body must reach the file unexpanded
  _ps1=$(supp_fixture src/probe.ps1 \
    '$a = Get-Item "p" -ErrorAction SilentlyContinue' \
    '$null = Get-Item "r"' \
    '[void](Get-Item "u")' \
    '& cmd /c ver 2>$null')
  _sh=$(supp_fixture src/probe.sh "probe_cmd || true")
  _root=$(fixture_root "$_ps1")
  _sh_root=$(fixture_root "$_sh")
  run_supp_scan "$_ps1" "$_sh"
  _ps1_lines=$(printf '%s\n' "$_out" | grep -c "$_ps1:[0-9][0-9]* (")
  _sh_lines=$(printf '%s\n' "$_out" | grep -c 'undoc_supp:')
  rm -rf "$_root" "$_sh_root"
  if [ "$_ps1_lines" -ne 4 ] || [ "$_sh_lines" -ne 1 ]; then
    fail "expected 4 PowerShell and 1 shell violation, got $_ps1_lines and $_sh_lines" "$_out"
    return 1
  fi
  for _expected in \
    "$_ps1:1 (-ErrorAction SilentlyContinue)" \
    "$_ps1:2 (\$null =)" \
    "$_ps1:3 ([void])" \
    "$_ps1:4 (2>\$null)" \
    "undoc_supp:$_sh:1:|| true: probe_cmd || true"; do
    if ! supp_reports "$_expected"; then
      fail "missing report line: $_expected" "$_out"
      return 1
    fi
  done
  return 0
}

# The `|| true` rule covers shell and Nix only. The twin feeds its rule the same
# two lists, so a PowerShell 7 chain operator is not a shell suppression and a
# .ps1 file must not be reported for it. Without this, a program that applied
# every pattern to every file still passes the mixed-family test above. The shell
# file in the same call is the control, so the case cannot pass against a scan
# that read nothing.
test_posix_or_true_is_shell_only() {
  local _ps1 _control
  _ps1=$(supp_fixture src/probe.ps1 'Get-Item "p" || true')
  _control=$(supp_fixture src/control.sh "probe_cmd || true")
  run_supp_scan "$_ps1" "$_control"
  rm -rf "$(fixture_root "$_ps1")" "$(fixture_root "$_control")"
  if ! supp_only_control_reported "$_ps1" "undoc_supp:$_control:1:|| true: probe_cmd || true"; then
    return 1
  fi
  return 0
}

posix_failures=0
for test in \
  test_posix_unannotated_shellcheck_disable_is_reported \
  test_posix_documented_shellcheck_disable_is_accepted \
  test_posix_bare_or_true_is_reported \
  test_posix_documented_or_true_is_accepted \
  test_posix_annotation_does_not_cross_files \
  test_posix_or_true_is_shell_only \
  test_posix_or_true_tests_directory_exemption \
  test_posix_mixed_family_scan_reports_each_shape; do
  if ! "$test"; then
    echo "FAIL: $test"
    posix_failures=$((posix_failures + 1))
  fi
done

if [ "$posix_failures" -ne 0 ]; then
  echo "FAIL: $posix_failures POSIX suppression audit test(s) failed"
  exit 1
fi
echo "PASS: POSIX suppression audit"
