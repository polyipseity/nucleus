#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2031 # reason: test functions intentionally isolate REPO_ROOT in subshells
# Test: step 14 repository-policy behavioral tests
# All grep-only tests (that checked implementation text) have been removed.
# These tests exercise the actual check functions against fixture data.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/14-repository-policy.sh"

# shellcheck source=../../../src/scripts/checks/check-steps/14-repository-policy.sh
. "$TEST_FILE"

# --- activation naming policy behavioral tests ---

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

# --- logging format policy behavioral tests ---

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

# --- nix file structure behavioral tests ---

test_step14_nix_file_structure_pattern1_detection() {
  local _tmp
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/src/testmod"
  touch "$_tmp/src/testmod.nix"
  mkdir -p "$_tmp/src/testmod"
  local _out
  _out=$(mktemp)
  # shellcheck source=/dev/null
  (cd "$_tmp" && mkdir -p src && git init -q && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    unset _NUCLEUS_STEP_RUNNER_SOURCED _NUCLEUS_CHECK_LIB_SOURCED && _STEP_IDS=() && . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
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
  # shellcheck source=/dev/null
  (cd "$_tmp" && mkdir -p src && git init -q && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    unset _NUCLEUS_STEP_RUNNER_SOURCED _NUCLEUS_CHECK_LIB_SOURCED && _STEP_IDS=() && . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
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
  # shellcheck source=/dev/null
  (cd "$_tmp" && mkdir -p src && git init -q && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    unset _NUCLEUS_STEP_RUNNER_SOURCED _NUCLEUS_CHECK_LIB_SOURCED && _STEP_IDS=() && . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
    declare -A ctx=([HAS_ARGS]=false [REPO_ROOT]="$_tmp") &&
    run_nix_file_structure false "$_tmp" 2>"$_out")
  local _ret=$?
  grep -q 'nix file structure passed' "$_out" || _ret=1
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

# --- log capture pair policy behavioral tests ---

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
  test_step14_naming_behavioral_positive \
  test_step14_naming_behavioral_negative \
  test_step14_naming_behavioral_exemption \
  test_step14_naming_behavioral_prefix \
  test_step14_logging_behavioral_positive \
  test_step14_logging_behavioral_negative \
  test_step14_logging_behavioral_allowlist \
  test_step14_nix_file_structure_pattern1_detection \
  test_step14_nix_file_structure_pattern2_detection \
  test_step14_nix_file_structure_valid_passes \
  test_step14_capture_pair_behavioral_positive \
  test_step14_capture_pair_behavioral_negative; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
