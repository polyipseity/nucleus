#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 14 repository-policy must enforce dummy-key registry uniformity
# and the logging format policy

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/14-repository-policy.sh"
AWK_FILE="$REPO_ROOT/src/scripts/checks/check-steps/repository-policy.awk"
REGISTRY_FILE="$REPO_ROOT/src/modules/dummy-keys.json"

test_step14_dummy_key_registry_read() {
  if grep -q 'dummy-keys.json' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should read the dummy-key registry from dummy-keys.json"
  return 1
}

test_step14_dummy_key_literal_pattern() {
  # Matches: the rule comment sk-[A-Za-z0-9]{4,}
  if grep -q 'sk-\[A-Za-z0-9\]{4,}' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should target sk-[A-Za-z0-9]{4,} API key literals"
  return 1
}

test_step14_dummy_key_error_path() {
  if grep -q 'unregistered dummy API key literal' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should error on unregistered dummy API key literals"
  return 1
}

test_step14_dummy_key_registered_value() {
  if grep -q 'sk-nucleus-dummy-litellm' "$REGISTRY_FILE"; then
    return 0
  fi
  echo "FAIL: dummy-key registry should register the sk-nucleus-dummy-litellm value"
  return 1
}

# --- activation naming policy tests ---

test_step14_naming_policy_present() {
  if grep -q 'activation naming policy' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should enforce the activation naming policy"
  return 1
}

test_step14_naming_kebab_regex() {
  if grep -Fq '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should validate activation names against the kebab-case regex"
  return 1
}

test_step14_naming_exemption_names() {
  if grep -qE 'linkGeneration|writeBoundary|checkLinkTargets|setupLaunchAgents|installPackages|preActivation|extraActivation|postActivation' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should exempt Home Manager built-in and nix-darwin hardcoded activation names"
  return 1
}

test_step14_naming_generated_exemption() {
  if grep -qE 'unprotectSymlink_\*|protectSymlink_\*|mergeConfig_\*' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should exempt config-utils.nix generated activation names"
  return 1
}

test_step14_naming_macos_prefix_error() {
  if grep -q 'lacks the macos- prefix' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should require the macos- prefix on macOS-only activation names"
  return 1
}

# Behavioral tests: run run_activation_naming_policy against fixture trees.

# shellcheck source=../../../src/scripts/checks/check-steps/14-repository-policy.sh
. "$TEST_FILE"

test_step14_naming_behavioral_positive() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules" "$_tmp/src/platforms/NixOS" "$_tmp/src/platforms/macOS" "$_tmp/src/hosts/MacBook"
  cat >"$_tmp/src/modules/good.nix" <<'EOF'
home.activation.provision-thing = lib.hm.dag.entryAfter ["writeBoundary"] "x";
system.activationScripts.gitconfig.text = lib.mkAfter "";
EOF
  cat >"$_tmp/src/platforms/NixOS/default.nix" <<'EOF'
home.activation.shared-thing = lib.hm.dag.entryAfter ["writeBoundary"] "x";
EOF
  cat >"$_tmp/src/platforms/macOS/default.nix" <<'EOF'
home.activation.shared-thing = lib.hm.dag.entryAfter ["writeBoundary"] "x";
home.activation.macos-setup-thing = lib.hm.dag.entryAfter ["writeBoundary"] "x";
EOF
  cat >"$_tmp/src/hosts/MacBook/default.nix" <<'EOF'
system.activationScripts.macos-deploy-thing.text = lib.mkAfter "";
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: valid kebab-case activation names should pass (incl. macos- prefix and cross-platform carve-out)"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_naming_behavioral_negative() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules"
  cat >"$_tmp/src/modules/bad.nix" <<'EOF'
home.activation.provisionDevRepos = lib.hm.dag.entryAfter ["writeBoundary"] "x";
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q 'is not kebab-case' "$_out"; then
    echo "FAIL: camelCase activation name should fail the kebab-case check"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_naming_behavioral_exemption() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules" "$_tmp/src/hosts/MacBook"
  cat >"$_tmp/src/modules/generated.nix" <<'EOF'
home.activation.unprotectSymlink_foo = lib.hm.dag.entryAfter ["writeBoundary"] "x";
home.activation.protectSymlink_foo = lib.hm.dag.entryAfter ["writeBoundary"] "x";
home.activation.mergeConfig_picard = lib.hm.dag.entryAfter ["writeBoundary"] "x";
EOF
  cat >"$_tmp/src/hosts/MacBook/activation.nix" <<'EOF'
system.activationScripts.preActivation.text = lib.mkAfter "";
system.activationScripts.extraActivation.text = lib.mkAfter "";
system.activationScripts.postActivation.text = lib.mkAfter "";
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: exempt activation names (generated, darwin hardcoded) should pass"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_naming_behavioral_prefix() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/hosts/MacBook"
  cat >"$_tmp/src/hosts/MacBook/services.nix" <<'EOF'
system.activationScripts.flush-services-cache.text = lib.mkAfter "";
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q 'lacks the macos- prefix' "$_out"; then
    echo "FAIL: macOS-only activation name without macos- prefix should fail"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# --- logging format policy tests ---

# Test-file note: these tests reference the policy's message strings, never the
# banned literals themselves, so this file stays clean under the scan it tests.

test_step14_logging_policy_present() {
  if grep -q 'logging format policy' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should enforce the logging format policy"
  return 1
}

test_step14_logging_ansi_pattern() {
  if grep -q 'raw ANSI escape literal' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should flag raw ANSI escape literals"
  return 1
}

test_step14_logging_termcap_pattern() {
  if grep -q 'terminal capability query' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should flag terminal capability queries"
  return 1
}

test_step14_logging_echo_e_pattern() {
  if grep -q 'echo dash-e flag' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should flag the echo dash-e flag"
  return 1
}

test_step14_logging_char27_pattern() {
  if grep -q 'char-27 escape literal' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should flag char-27 escape literals"
  return 1
}

test_step14_logging_backtick_e_pattern() {
  if grep -q 'backtick-e escape literal' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should flag backtick-e escape literals"
  return 1
}

test_step14_logging_skip_marker_pattern() {
  if grep -q 'legacy skip marker' "$AWK_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should flag legacy skip markers"
  return 1
}

test_step14_logging_allowlist() {
  if grep -q 'Invoke-LogManagement.ps1' "$REPO_ROOT/src/scripts/checks/check-steps/14-repository-policy.ps1" && grep -q 'log-management.Tests.ps1' "$REPO_ROOT/src/scripts/checks/check-steps/14-repository-policy.ps1"; then
    return 0
  fi
  echo "FAIL: step 14 should allowlist the log sanitizer and its tests"
  return 1
}

test_step14_logging_self_check() {
  if grep -q 'NO_COLOR' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should self-check NO_COLOR handling in shared helpers"
  return 1
}

test_step14_logging_ps1_twin() {
  if grep -q 'logging format policy' "$REPO_ROOT/src/scripts/checks/check-steps/14-repository-policy.ps1"; then
    return 0
  fi
  echo "FAIL: step 14 .ps1 twin should enforce the logging format policy"
  return 1
}

# Behavioral tests: run run_logging_format_policy against fixture trees.
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/logging-format"
CAPTURE_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/log-capture-pair"

test_step14_logging_behavioral_positive() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  cp "$FIXTURE_DIR/clean.sh" "$_tmp/clean.sh"
  cp "$FIXTURE_DIR/clean.ps1" "$_tmp/clean.ps1"
  run_logging_format_policy true "$_tmp" "$_tmp/clean.sh" "$_tmp/clean.ps1" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: clean shell and PowerShell files should pass the logging format policy"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_logging_behavioral_negative() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  cp "$FIXTURE_DIR/violations.sh" "$_tmp/violations.sh"
  cp "$FIXTURE_DIR/violations.ps1" "$_tmp/violations.ps1"
  run_logging_format_policy true "$_tmp" "$_tmp/violations.sh" "$_tmp/violations.ps1" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q 'raw ANSI escape literal' "$_out" || ! grep -q 'terminal capability query' "$_out" || ! grep -q 'echo dash-e flag' "$_out" || ! grep -q 'char-27 escape literal' "$_out" || ! grep -q 'backtick-e escape literal' "$_out"; then
    echo "FAIL: prohibited logging constructs should fail the logging format policy"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_logging_behavioral_allowlist() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  cp "$FIXTURE_DIR/lib.sh" "$_tmp/lib.sh"
  cp "$FIXTURE_DIR/Format-NucleusOutput.psm1" "$_tmp/Format-NucleusOutput.psm1"
  run_logging_format_policy true "$_tmp" "$_tmp/lib.sh" "$_tmp/Format-NucleusOutput.psm1" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: allowlisted helper files should pass the logging format policy"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

# --- nix file structure tests ---

test_step14_nix_file_structure_present() {
  grep -q 'run_nix_file_structure' "$TEST_FILE"
}

test_step14_nix_file_structure_pattern1_detection() {
  local _tmp
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/src/testmod"
  touch "$_tmp/src/testmod.nix"
  mkdir -p "$_tmp/src/testmod"
  local _out
  _out=$(mktemp)
  # Source the check-lib to get filter_gitignored, then source the step
  (cd "$_tmp" && mkdir -p src && git init -q && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
    declare -A ctx=([HAS_ARGS]=false [REPO_ROOT]="$_tmp") &&
    run_nix_file_structure false "$_tmp" 2>"$_out" || true)
  local _ret=0
  grep -q 'exists alongside directory' "$_out" || _ret=1
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: Pattern 1 not detected"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_nix_file_structure_pattern2_detection() {
  local _tmp
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/src/mymod"
  touch "$_tmp/src/mymod/mymod.nix"
  local _out
  _out=$(mktemp)
  (cd "$_tmp" && mkdir -p src && git init -q && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
    declare -A ctx=([HAS_ARGS]=false [REPO_ROOT]="$_tmp") &&
    run_nix_file_structure false "$_tmp" 2>"$_out" || true)
  local _ret=0
  grep -q 'same name as parent directory' "$_out" || _ret=1
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: Pattern 2 not detected"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_nix_file_structure_valid_passes() {
  local _tmp
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/src/mymod"
  touch "$_tmp/src/mymod/default.nix"
  local _out
  _out=$(mktemp)
  (cd "$_tmp" && mkdir -p src && git init -q && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
    declare -A ctx=([HAS_ARGS]=false [REPO_ROOT]="$_tmp") &&
    run_nix_file_structure false "$_tmp" 2>"$_out")
  local _ret=$?
  grep -q 'nix file structure passed' "$_out" || _ret=1
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

# --- log capture pair policy tests ---

test_step14_capture_pair_policy_present() {
  if grep -q 'log capture pair policy' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should enforce the log capture pair policy"
  return 1
}

test_step14_capture_pair_devnull_pattern() {
  if grep -Fq 'discards a stream to /dev/null' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should reject a capture directive that discards a stream"
  return 1
}

test_step14_capture_pair_merged_pattern() {
  # Literal phrase only: embedding the merged-redirection token here would make this
  # test file self-trip the policy it exercises.
  if grep -Fq 'merges stdout and stderr' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should reject a merged-stream redirection"
  return 1
}

test_step14_capture_pair_lone_stream_pattern() {
  if grep -Fq 'declares only one of StandardOutPath/StandardErrorPath' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 14 should reject a lone capture stream"
  return 1
}

test_step14_capture_pair_behavioral_positive() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  cp "$CAPTURE_FIXTURE_DIR/clean.nix" "$_tmp/clean.nix"
  cp "$CAPTURE_FIXTURE_DIR/clean.ps1" "$_tmp/clean.ps1"
  run_log_capture_pair_policy true "$_tmp" "$_tmp/clean.nix" "$_tmp/clean.ps1" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: a correct stdout.log/stderr.log pair should pass the log capture pair policy"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_capture_pair_behavioral_negative() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  cp "$CAPTURE_FIXTURE_DIR/violations.nix" "$_tmp/violations.nix"
  cp "$CAPTURE_FIXTURE_DIR/violations.ps1" "$_tmp/violations.ps1"
  cp "$CAPTURE_FIXTURE_DIR/lone.nix" "$_tmp/lone.nix"
  run_log_capture_pair_policy true "$_tmp" "$_tmp/violations.nix" "$_tmp/violations.ps1" "$_tmp/lone.nix" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q 'discards a stream to /dev/null' "$_out" || ! grep -q 'merges stdout and stderr' "$_out" || ! grep -q 'declares only one of StandardOutPath/StandardErrorPath' "$_out"; then
    echo "FAIL: prohibited log capture constructs should fail the log capture pair policy"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

failures=0
for test in \
  test_step14_dummy_key_registry_read \
  test_step14_dummy_key_literal_pattern \
  test_step14_dummy_key_error_path \
  test_step14_dummy_key_registered_value \
  test_step14_naming_policy_present \
  test_step14_naming_kebab_regex \
  test_step14_naming_exemption_names \
  test_step14_naming_generated_exemption \
  test_step14_naming_macos_prefix_error \
  test_step14_naming_behavioral_positive \
  test_step14_naming_behavioral_negative \
  test_step14_naming_behavioral_exemption \
  test_step14_naming_behavioral_prefix \
  test_step14_logging_policy_present \
  test_step14_logging_ansi_pattern \
  test_step14_logging_termcap_pattern \
  test_step14_logging_echo_e_pattern \
  test_step14_logging_char27_pattern \
  test_step14_logging_backtick_e_pattern \
  test_step14_logging_skip_marker_pattern \
  test_step14_logging_allowlist \
  test_step14_logging_self_check \
  test_step14_logging_ps1_twin \
  test_step14_logging_behavioral_positive \
  test_step14_logging_behavioral_negative \
  test_step14_logging_behavioral_allowlist \
  test_step14_nix_file_structure_present \
  test_step14_nix_file_structure_pattern1_detection \
  test_step14_nix_file_structure_pattern2_detection \
  test_step14_nix_file_structure_valid_passes \
  test_step14_capture_pair_policy_present \
  test_step14_capture_pair_devnull_pattern \
  test_step14_capture_pair_merged_pattern \
  test_step14_capture_pair_lone_stream_pattern \
  test_step14_capture_pair_behavioral_positive \
  test_step14_capture_pair_behavioral_negative; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
