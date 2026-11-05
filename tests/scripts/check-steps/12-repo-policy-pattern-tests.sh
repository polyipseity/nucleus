#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2031 # reason: test functions intentionally isolate REPO_ROOT in subshells
# Test: repo-policy-pattern (check step 12) behavioral tests.
# The naming, logging-format, nix-file-structure and log-capture-pair policies
# live in step 12. These tests exercise the actual check functions against
# fixture data rather than grepping their implementation text.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/12-repo-policy-pattern.sh"

# shellcheck source=../../../src/scripts/checks/check-steps/12-repo-policy-pattern.sh
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

# --- activation naming policy: attrset regions (one awk pass) ---
# A `<namespace> = { ... };` block yields entries through the shared awk program.
# These cases pin the record set it produces: which lines the region covers, that
# the region closes on brace depth, and that no block state carries from one file
# to the next. A record only reaches the output as a violation report, so each
# fixture names its entries so that every captured record has to be reported and
# every uncaptured one has to stay silent.

test_step14_naming_region_scopes_attrset_block() {
  local _tmp _out _ret _count
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules"
  cat >"$_tmp/src/modules/region.nix" <<'EOF'
{ lib, ... }:
{
  badBefore = lib.mkAfter "";

  home.activation = {
    badInside = lib.mkAfter "";
    badDotted.text = lib.mkAfter "";
    valid-inside = lib.mkAfter "";
  };

  badAfter = lib.mkAfter "";
}
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  _count=$(grep -cF 'is not kebab-case' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_count" -ne 2 ]; then
    echo "FAIL: expected the two in-block entries reported, got $_count (exit $_ret)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! grep -Fq "activation name 'badInside' at src/modules/region.nix:6 is not kebab-case" "$_out"; then
    echo "FAIL: the entry inside the block is not reported at its own line"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  # A dotted key inside the block is the entry named by its first segment, not by
  # the trailing attribute.
  if ! grep -Fq "activation name 'badDotted' at src/modules/region.nix:7 is not kebab-case" "$_out"; then
    echo "FAIL: a dotted key inside the block is not reported by its first segment"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if grep -Fq 'badBefore' "$_out" || grep -Fq 'badAfter' "$_out"; then
    echo "FAIL: an entry line outside the block was reported"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# The region ends when its brace depth returns to zero, so a nested attrset keeps
# it open. A region that never closes keeps the file in scope, and the
# between-blocks line and the second block would both be reported.
test_step14_naming_region_ends_at_closing_brace() {
  local _tmp _out _ret _count
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules"
  cat >"$_tmp/src/modules/blocks.nix" <<'EOF'
{ lib, ... }:
{
  home.activation = {
    badFirst = lib.mkAfter "";
  };

  badBetween = lib.mkAfter "";

  system.activationScripts = {
    badSecond = lib.mkAfter "";
  };
}
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  _count=$(grep -cF 'is not kebab-case' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_count" -ne 2 ]; then
    echo "FAIL: expected one entry reported per block, got $_count (exit $_ret)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! grep -Fq "'badFirst' at src/modules/blocks.nix:4 is not kebab-case" "$_out" ||
    ! grep -Fq "'badSecond' at src/modules/blocks.nix:10 is not kebab-case" "$_out"; then
    echo "FAIL: a block entry is not reported at its own line"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if grep -Fq 'badBetween' "$_out"; then
    echo "FAIL: a line between two blocks was reported as an entry"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# The region closes on brace depth, so a nested attrset does not end it and the
# entries after the nested close are still scanned. The shape is the one at
# src/platforms/macOS/modules/default.nix:330-346: a namespace, an entry, a nested
# attrset with `command` and `order`, then more entries.
test_step14_naming_nested_attrset_keeps_scanning() {
  local _tmp _out _ret _count
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules"
  cat >"$_tmp/src/modules/nested.nix" <<'EOF'
{ lib, ... }:
{
  home.activation = {
    badEntry = lib.mkAfter "";
    badWrapper = {
      command = "x";
      order = 50;
    };
    badAfterClose = lib.mkAfter "";
  };
}
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  _count=$(grep -cF 'is not kebab-case' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_count" -ne 2 ]; then
    echo "FAIL: expected the entries before and after the nested attrset reported, got $_count (exit $_ret)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! grep -Fq "'badEntry' at src/modules/nested.nix:4 is not kebab-case" "$_out"; then
    echo "FAIL: the entry before the nested attrset was not reported"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! grep -Fq "'badAfterClose' at src/modules/nested.nix:9 is not kebab-case" "$_out"; then
    echo "FAIL: the entry after the nested close was not reported"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if grep -Fq 'badWrapper' "$_out"; then
    echo "FAIL: the attrset-valued wrapper was reported as an entry"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Both files open a block and never close it, and both place a violating entry
# line before their block. A scan that carries the open block into the next file
# reports the second file's leading line, whichever file the discovery yields
# first; a scan that resets per file reports nothing.
test_step14_naming_region_state_does_not_cross_files() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules"
  cat >"$_tmp/src/modules/a-open.nix" <<'EOF'
{ lib, ... }:
{
  badLeadingA = lib.mkAfter "";
  home.activation = {
    valid-a = lib.mkAfter "";
EOF
  cat >"$_tmp/src/modules/b-open.nix" <<'EOF'
{ lib, ... }:
{
  badLeadingB = lib.mkAfter "";
  home.activation = {
    valid-b = lib.mkAfter "";
EOF
  run_activation_naming_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ] || grep -Fq 'is not kebab-case' "$_out"; then
    echo "FAIL: an unclosed block leaked into the next file (exit $_ret)"
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
  (cd "$_tmp" && mkdir -p src && git init -q && git config user.email "test@example.com" && git config user.name "Test User" && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    unset _NUCLEUS_STEP_RUNNER_SOURCED _NUCLEUS_CHECK_LIB_SOURCED && _STEP_IDS=() && . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
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
  (cd "$_tmp" && mkdir -p src && git init -q && git config user.email "test@example.com" && git config user.name "Test User" && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    unset _NUCLEUS_STEP_RUNNER_SOURCED _NUCLEUS_CHECK_LIB_SOURCED && _STEP_IDS=() && . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
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
  (cd "$_tmp" && mkdir -p src && git init -q && git config user.email "test@example.com" && git config user.name "Test User" && touch src/.gitkeep && git add . && git commit -q -m 'init' &&
    unset _NUCLEUS_STEP_RUNNER_SOURCED _NUCLEUS_CHECK_LIB_SOURCED && _STEP_IDS=() && . "$REPO_ROOT/src/scripts/checks/check-lib.sh" &&
    . "$TEST_FILE" &&
    run_nix_file_structure false "$_tmp" >"$_out" 2>&1)
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

# The removed-skip list must cover the test-harness skip counter. The tokens are
# composed at runtime: step 12 scans tracked .sh files, this file included, so a
# literal token here would be a finding against the gate's own test.
test_step14_removed_skip_constructs_detection() {
  local _tmp _out _assert_token _counter_token
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  _assert_token="assert""_skip"
  _counter_token="TESTS_""SKIP""PED"
  printf '%s case-name case-reason\n' "$_assert_token" >"$_tmp/violating.sh"
  printf 'echo "$%s"\n' "$_counter_token" >>"$_tmp/violating.sh"
  awk -v mode=skip-constructs -f "$REPO_ROOT/src/scripts/checks/check-steps/repository-policy.awk" "$_tmp/violating.sh" >"$_out" 2>&1
  if ! grep -q "$_assert_token" "$_out" || ! grep -q "$_counter_token" "$_out"; then
    echo "FAIL: the removed skip list must report $_assert_token and $_counter_token"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  printf 'plain_function() { :; }\n' >"$_tmp/clean.sh"
  awk -v mode=skip-constructs -f "$REPO_ROOT/src/scripts/checks/check-steps/repository-policy.awk" "$_tmp/clean.sh" >"$_out" 2>&1
  if [ -s "$_out" ]; then
    echo "FAIL: a clean shell file must report no removed skip construct"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# --- envrc ban policy behavioral tests ---

test_step14_envrc_ban_root_fails() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  touch "$_tmp/.envrc"
  run_envrc_ban_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q "envrc ban: '.envrc' exists; delete it" "$_out"; then
    echo "FAIL: a root-level .envrc must fail the envrc ban policy and name the path"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_envrc_ban_nested_fails() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/sub/dir"
  touch "$_tmp/sub/dir/.envrc"
  run_envrc_ban_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q "envrc ban: 'sub/dir/.envrc' exists; delete it" "$_out"; then
    echo "FAIL: a nested .envrc must fail the envrc ban policy and name the relative path"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_envrc_ban_clean_tree_passes() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/sub"
  touch "$_tmp/sub/script.sh"
  run_envrc_ban_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ] || ! grep -q 'envrc ban policy passed' "$_out"; then
    echo "FAIL: a tree without .envrc must pass the envrc ban policy"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_envrc_ban_scoped_mode_fails() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  touch "$_tmp/.envrc"
  run_envrc_ban_policy true "$_tmp" "$_tmp/.envrc" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -q "envrc ban: '$_tmp/.envrc' exists; delete it" "$_out"; then
    echo "FAIL: scoped mode must fail when the given path is an .envrc"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_envrc_ban_pruned_decoys_ignored() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  # The find prune must skip .git and vendor at any depth and report only the real
  # offender. A top-level .git and a nested .git both appear so the test fails if
  # the prune ever drops back to excluding only the top-level .git. The real
  # offender sits outside the pruned dirs so the run still fails, which is what
  # proves the decoys were skipped rather than the whole scan being inert.
  mkdir -p "$_tmp/.git" "$_tmp/vendor" "$_tmp/nested/.git" "$_tmp/real"
  touch "$_tmp/.git/.envrc"
  touch "$_tmp/vendor/.envrc"
  touch "$_tmp/nested/.git/.envrc"
  touch "$_tmp/real/.envrc"
  run_envrc_ban_policy false "$_tmp" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ]; then
    echo "FAIL: a real .envrc outside the pruned dirs must still fail the envrc ban policy (run exited 0)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! grep -qF "envrc ban: 'real/.envrc' exists; delete it" "$_out"; then
    echo "FAIL: the report must name the real offender by its path 'real/.envrc'"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  # Fixed-string matching so a decoy literal cannot false-positive on the real
  # path, whose reported string carries the same .envrc suffix.
  local _decoy
  for _decoy in ".git/.envrc" "vendor/.envrc" "nested/.git/.envrc"; do
    if grep -qF "envrc ban: '$_decoy' exists" "$_out"; then
      echo "FAIL: the decoy '$_decoy' sits in a pruned dir and must not be reported"
      cat "$_out"
      rm -rf "$_tmp"
      rm -f "$_out"
      return 1
    fi
  done
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# --- config method compliance behavioral tests ---
# Ruling R7: the POSIX twin mirrors the .ps1 annotation rule. A config file
# referenced from src/ (outside configs/) needs a "# check-suppress:config-method"
# comment on the reference line or within the 10 lines above it.

# Build a fixture tree holding one config and a referencing src file.
# Remaining args become the lines of src/probe-deploy.sh. Prints the root.
cfg_method_fixture() {
  local _root
  _root=$(mktemp -d)
  mkdir -p "$_root/src/modules/configs/probe"
  printf '%s\n' '{"probe": true}' >"$_root/src/modules/configs/probe/settings.json"
  printf '%s\n' "$@" >"$_root/src/probe-deploy.sh"
  printf '%s\n' "$_root"
}

test_step14_config_method_unannotated_reference_fails() {
  local _tmp _out _ret
  _tmp=$(cfg_method_fixture 'deploy "src/modules/configs/probe/settings.json"')
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF "referenced but no '# check-suppress:config-method' comment found on or before reference lines" "$_out" || ! grep -qF 'probe/settings.json : referenced' "$_out"; then
    echo "FAIL: a referenced config without the annotation must fail and name the config"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Case-fold divergence pin: both twins read config-method references
# case-insensitively, so a case-variant basename reference still needs the
# annotation (comments at the grep -Fi site and the .ps1 pattern build).
test_step14_config_method_case_variant_reference_fails() {
  local _tmp _out _ret
  _tmp=$(cfg_method_fixture 'deploy "src/modules/configs/probe/SETTINGS.JSON"')
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF "probe/settings.json : referenced" "$_out"; then
    echo "FAIL: a case-variant config reference must be flagged (case-insensitive reading on both twins)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Empty config list pin: both twins report the shared counted pass message
# (`config method compliance passed (0 configs).`); the .ps1 early-returns
# before its scan, where an empty pattern list would `-match` every line.
test_step14_config_method_empty_config_list_reports_counted_pass() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/src/modules/configs"
  printf '%s\n' 'echo hi' >"$_tmp/src/probe-deploy.sh"
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ] || ! grep -qF "config method compliance passed (0 configs)." "$_out"; then
    echo "FAIL: an empty config list must pass with the counted message both twins share"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Bracketed filename pin: a source file named with [ must still resolve and
# flag its unannotated reference; the .ps1 twin needs -LiteralPath for the
# same path, because Get-Content -Path wildcard-matches [ and reads nothing.
test_step14_config_method_bracket_filename_resolves() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/src/modules/configs/probe"
  printf '%s\n' '{"probe": true}' >"$_tmp/src/modules/configs/probe/settings.json"
  printf '%s\n' 'deploy "src/modules/configs/probe/settings.json"' >"$_tmp/src/probe[1].sh"
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe[1].sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF "probe/settings.json : referenced" "$_out"; then
    echo "FAIL: a bracketed source filename must resolve and flag the unannotated reference"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Dot-prefixed template-tier guard pin (.sh guard at the config loop): a
# basename whose stem is empty gets no ${hostName} template pattern, and the
# reference still resolves through the basename tier, so the annotated fixture
# under tests/fixtures/ passes.
test_step14_config_method_dot_prefixed_config_guard_fires() {
  local _ret _out
  _out=$(mktemp)
  run_config_method_compliance true "$REPO_ROOT/tests/fixtures/config-method-dot-prefixed" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ] || ! grep -qF "config method compliance passed." "$_out"; then
    echo "FAIL: a dot-prefixed config must resolve through the basename tier with no template pattern"
    cat "$_out"
    rm -f "$_out"
    return 1
  fi
  rm -f "$_out"
  return 0
}

test_step14_config_method_parallel_reports_input_order() {
  local _tmp _out _driver _aaa_line _zzz_line
  if ! command -v pwsh >/dev/null 2>&1; then
    echo "FAIL: pwsh is required to run the PowerShell twin's config-method corpus"
    return 1
  fi
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  _driver="$_tmp/twin-driver.ps1"
  mkdir -p "$_tmp/src/modules/configs"
  printf '%s\n' '{}' >"$_tmp/src/modules/configs/aaa.conf"
  printf '%s\n' '{}' >"$_tmp/src/modules/configs/zzz.conf"
  awk 'BEGIN { for (i = 1; i <= 600; i++) print "deploy \"src/modules/configs/aaa.conf\"" }' >"$_tmp/src/probe-deploy.sh"
  cat >"$_driver" <<'DRIVER'
# Test driver: runs the real 12-repo-policy-pattern.ps1 action against a
# fixture root, stubbing only the four functions the check pipeline provides.
$ErrorActionPreference = 'Continue'
function Register-Step {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Name,
    [string]$Platform,
    [string]$Mode,
    [string]$Requires,
    [Parameter(Mandatory)][scriptblock]$Action
  )
  $script:stepAction = $Action
}
function Write-Message { param([Parameter(Mandatory, Position = 0)][string]$Message) Write-Output $Message }
function Write-ErrorMessage { param([Parameter(Mandatory, Position = 0)][string]$Message) Write-Output "ERROR: $Message" }
function Select-GitIgnored { process { "$_" } }

$repoRoot = $args[0]
$fixtureRoot = $args[1]
. (Join-Path $repoRoot 'src/scripts/checks/check-steps/12-repo-policy-pattern.ps1')
Set-Location $fixtureRoot
$ctx = [pscustomobject]@{
  HasArgs        = $false
  RepoRoot       = $fixtureRoot
  PositionalArgs = @()
  NixFiles       = $null
}
& $script:stepAction $ctx
DRIVER
  pwsh -NoLogo -NoProfile -NonInteractive -File "$_driver" "$REPO_ROOT" "$_tmp" >"$_out" 2>&1
  _aaa_line=$(grep -nF 'aaa.conf : referenced but no' "$_out" | head -n 1 | cut -d: -f1)
  _zzz_line=$(grep -nF 'zzz.conf : no references found' "$_out" | head -n 1 | cut -d: -f1)
  if [ -z "$_aaa_line" ] || [ -z "$_zzz_line" ] || [ "$_aaa_line" -ge "$_zzz_line" ]; then
    echo "FAIL: two config errors must report in input index order (aaa.conf before zzz.conf)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

test_step14_config_method_same_line_annotation_passes() {
  local _tmp _out _ret
  _tmp=$(cfg_method_fixture 'deploy "src/modules/configs/probe/settings.json" # check-suppress:config-method: method 1 (writable symlink)')
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: an annotation on the reference line must pass"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_config_method_preceding_annotation_passes() {
  local _tmp _out _ret
  _tmp=$(cfg_method_fixture \
    '# check-suppress:config-method: method 1 (writable symlink)' \
    '# deploy the shared probe settings' \
    ':' \
    'deploy "src/modules/configs/probe/settings.json"')
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: an annotation 3 lines above the reference must pass"
    cat "$_out"
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  [ "$_ret" -eq 0 ]
}

test_step14_config_method_window_is_10_lines() {
  local _tmp _out _ret
  # The annotation sits 11 lines above the reference, one outside the window
  # the .ps1 twin scans, so this must fail. It pins the window width.
  _tmp=$(cfg_method_fixture \
    '# check-suppress:config-method: method 1 (writable symlink)' \
    '# filler 01' '# filler 02' '# filler 03' '# filler 04' '# filler 05' \
    '# filler 06' '# filler 07' '# filler 08' '# filler 09' '# filler 10' \
    'deploy "src/modules/configs/probe/settings.json"')
  _out=$(mktemp)
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF "referenced but no '# check-suppress:config-method' comment found" "$_out"; then
    echo "FAIL: an annotation 11 lines above the reference must fail (10-line window)"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# ---------------------------------------------------------------------------
# Config method compliance: one reference index
#
# The rule now answers every config from a single bulk scan of the reference
# files instead of running three whole-tree greps per config. These cases pin
# the two things that rewrite could silently break: the number of scans, and the
# tier reading (the relative-path tier replaces the basename tier, and the
# ${hostName} template tier answers a config no raw basename matches).
# ---------------------------------------------------------------------------

# A grep that counts itself before forwarding to the real one. $1 is the shim
# directory; the real grep arrives as $NUCLEUS_REAL_GREP, captured before the
# shim directory joins PATH.
grep_counting_shim() {
  local _gcs_dir="$1"
  cat >"$_gcs_dir/grep" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$NUCLEUS_GREP_LOG"
exec "$NUCLEUS_REAL_GREP" "$@"
EOF
  chmod +x "$_gcs_dir/grep"
}

# Five dotted configs, each referenced by basename only, so a per-config scan
# shape spends a relative-path grep and a basename grep on every config. The
# violations that still surface prove the shim did not disarm the rule.
test_step14_config_method_reference_index_scan_count() {
  local _tmp _out _log _shim _ret _count _real_grep _name
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  _log=$(mktemp)
  _shim=$(mktemp -d)
  for _name in alpha bravo charlie delta echo; do
    mkdir -p "$_tmp/src/modules/configs/$_name"
    printf '%s\n' '{"probe": true}' >"$_tmp/src/modules/configs/$_name/$_name.json"
    printf 'deploy "%s.json"\n' "$_name" >>"$_tmp/src/probe-deploy.sh"
  done
  _real_grep=$(command -v grep)
  grep_counting_shim "$_shim" "$_real_grep"
  _ret=0
  NUCLEUS_GREP_LOG="$_log" NUCLEUS_REAL_GREP="$_real_grep" PATH="$_shim:$PATH" \
    run_config_method_compliance true "$_tmp" >"$_out" 2>&1 || _ret=$?
  _count=$(wc -l <"$_log")
  _count="${_count// /}"
  if [ "$_ret" -eq 0 ] || ! grep -qF "referenced but no '# check-suppress:config-method' comment found" "$_out"; then
    echo "FAIL: the unannotated configs must still be reported through the counting shim"
    cat "$_out"
    rm -rf "$_tmp" "$_shim"
    rm -f "$_out" "$_log"
    return 1
  fi
  if [ "$_count" -gt 3 ]; then
    echo "FAIL: expected at most three grep scans (annotation, basename, template index), got $_count"
    cat "$_log"
    rm -rf "$_tmp" "$_shim"
    rm -f "$_out" "$_log"
    return 1
  fi
  rm -rf "$_tmp" "$_shim"
  rm -f "$_out" "$_log"
  return 0
}

# A config referenced twice: the basename reference carries an annotation, the
# relative-path reference 19 lines below does not. A tier that widens instead of
# replacing (union of both tiers) passes on the annotated basename line; the
# relative-path tier replaces it, so this must fail.
test_step14_config_method_relative_tier_beats_basename() {
  local _tmp _out _ret _i
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules/configs/probe"
  printf '%s\n' '{"probe": true}' >"$_tmp/src/modules/configs/probe/settings.json"
  {
    printf '%s\n' '# check-suppress:config-method: method 1 (writable symlink)'
    printf 'echo %s\n' 'settings.json'
    for _i in $(seq 1 18); do printf '# filler %02d\n' "$_i"; done
    printf '%s\n' 'deploy "src/modules/configs/probe/settings.json"'
  } >"$_tmp/src/probe-deploy.sh"
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF 'probe/settings.json : referenced but no' "$_out"; then
    echo "FAIL: the relative-path tier must replace the annotated basename tier and fail"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# A host-config file is referenced only through the ${hostName} template, so the
# answer depends on the template tier built from the basename's extension
# suffix. Unannotated fails, annotated on the same line passes.
test_step14_config_method_template_tier_reference() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules/configs/git"
  printf '%s\n' '[user]' >"$_tmp/src/modules/configs/git/MacBook.gitconfig"
  # shellcheck disable=SC2016 # reason: the fixture writes the literal template token, not a shell expansion
  printf '%s\n' 'write "${hostName}.gitconfig"' >"$_tmp/src/probe-deploy.sh"
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF 'git/MacBook.gitconfig : referenced but no' "$_out"; then
    echo "FAIL: a template-only reference must be found by the template tier and fail unannotated"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  # shellcheck disable=SC2016 # reason: the fixture writes the literal template token, not a shell expansion
  printf '%s\n' 'write "${hostName}.gitconfig" # check-suppress:config-method: method 1 (writable symlink)' >"$_tmp/src/probe-deploy.sh"
  run_config_method_compliance true "$_tmp" "$_tmp/src/probe-deploy.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -ne 0 ]; then
    echo "FAIL: the annotated template reference must pass"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# The rule is whole-repo in both modes by design: a config's verdict depends on
# references that can live in any src/ file, so a scoped subset cannot prove an
# annotation absent. A scoped run that listed an unrelated file must still catch
# a violation in a file it was not given; a scoped implementation would drop the
# config and pass.
test_step14_config_method_scoped_run_checks_whole_repo() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  mkdir -p "$_tmp/src/modules/configs/probe"
  printf '%s\n' '{"probe": true}' >"$_tmp/src/modules/configs/probe/settings.json"
  printf '%s\n' 'deploy "src/modules/configs/probe/settings.json"' >"$_tmp/src/probe-deploy.sh"
  printf '%s\n' ':' >"$_tmp/src/unrelated.sh"
  run_config_method_compliance true "$_tmp" "$_tmp/src/unrelated.sh" >"$_out" 2>&1
  _ret=$?
  if [ "$_ret" -eq 0 ] || ! grep -qF 'probe/settings.json : referenced but no' "$_out"; then
    echo "FAIL: a scoped run must still check every config against every reference file"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# The step-file exclusion is by basename, so a step file at any depth is out of
# every policy scan while an ordinary file at the same depth stays in. This pins
# the parameter-expansion basename read that replaced a fork per file.
test_step14_policy_scan_target_nested_basename() {
  local _ret=0
  if _policy_scan_target "src/scripts/deep/dir/12-repo-policy-pattern.sh" '\.(sh|zsh)$'; then
    echo "FAIL: a step file at depth must be excluded by basename"
    _ret=1
  fi
  if ! _policy_scan_target "src/scripts/deep/dir/deploy.sh" '\.(sh|zsh)$'; then
    echo "FAIL: an ordinary shell file at depth must stay a scan target"
    _ret=1
  fi
  if _policy_scan_target "vendor/deep/deploy.sh" '\.(sh|zsh)$'; then
    echo "FAIL: a vendored path must stay out of scans"
    _ret=1
  fi
  [ "$_ret" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Log capture pair policy: one pass, exact messages
#
# The rule reads four stream positions per file (launchd out/err, systemd
# out/err) and two discard shapes, then reports them in a fixed order. These
# cases drive the real function over the fixture units and pin the whole
# message, line content included, so a pass that changed the text, dropped a
# stream position, or leaked flags across files fails them. Expected line
# content is read back out of the fixture, because this suite is itself scanned
# by the step and must not carry a literal capture directive.
# ---------------------------------------------------------------------------

# Copy a fixture set into a fresh directory and run the rule over the copies.
# $1: output file to fill; $2: directory for the copies; rest: fixture names.
capture_scan() {
  local _cs_out="$1" _cs_dir="$2"
  shift 2
  local _cs_copies=()
  local _cs_name
  for _cs_name in "$@"; do
    cp "$CAPTURE_FIXTURE_DIR/$_cs_name" "$_cs_dir/$_cs_name"
    _cs_copies+=("$_cs_dir/$_cs_name")
  done
  run_log_capture_pair_policy true "$_cs_dir" "${_cs_copies[@]}" >"$_cs_out" 2>&1
}

# Exact text present in the captured output. The runner prefix is the only part
# left out, because the runner owns it.
capture_reports() {
  grep -qF -- "$1" "$2"
}

# All four stream positions accepted in one call. A pass that reports a pair, or
# that treats 1>>/2>> as a merged redirection, fails here.
test_step14_capture_pair_all_stream_positions_pass() {
  local _tmp _out _ret
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" clean.nix clean.ps1 systemd-pair.nix
  _ret=$?
  if [ "$_ret" -ne 0 ] || capture_reports "log capture pair:" "$_out"; then
    echo "FAIL: a launchd pair, a systemd pair and a 1>>/2>> wrapper must pass"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! capture_reports "log capture pair policy passed." "$_out"; then
    echo "FAIL: the passing run did not report the policy as passed"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Both /dev/null directives are reported, with their file, line and line text.
# The count is what shows the second stream is not lost after the first hit.
test_step14_capture_pair_discard_message_is_exact() {
  local _tmp _out _ret _probe _line_out _line_err _count
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" violations.nix
  _ret=$?
  _probe="$_tmp/violations.nix"
  _line_out=$(sed -n '5p' "$CAPTURE_FIXTURE_DIR/violations.nix")
  _line_err=$(sed -n '6p' "$CAPTURE_FIXTURE_DIR/violations.nix")
  _count=$(grep -cF 'discards a stream to /dev/null' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_count" -ne 2 ]; then
    echo "FAIL: expected two discard reports, got $_count"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! capture_reports "log capture pair: '$_probe:5:$_line_out' discards a stream to /dev/null; capture stdout.log and stderr.log instead (output-handling.instructions.md)" "$_out" ||
    ! capture_reports "log capture pair: '$_probe:6:$_line_err' discards a stream to /dev/null; capture stdout.log and stderr.log instead (output-handling.instructions.md)" "$_out"; then
    echo "FAIL: the discard report does not carry the file, line and line text"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# The merged-stream report, exact, and exactly once.
test_step14_capture_pair_merged_message_is_exact() {
  local _tmp _out _ret _probe _line _count
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" violations.ps1
  _ret=$?
  _probe="$_tmp/violations.ps1"
  _line=$(sed -n '2p' "$CAPTURE_FIXTURE_DIR/violations.ps1")
  _count=$(grep -cF 'merges stdout and stderr' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_count" -ne 1 ]; then
    echo "FAIL: expected one merged-stream report, got $_count"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! capture_reports "log capture pair: '$_probe:2:$_line' merges stdout and stderr; use 1>> and 2>> into stdout.log and stderr.log" "$_out"; then
    echo "FAIL: the merged-stream report does not carry the file, line and line text"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# A launchd file capturing the error stream only. The message names the file and
# the directive family, and it is emitted once.
test_step14_capture_pair_lone_launchd_message_is_exact() {
  local _tmp _out _ret _probe
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" lone.nix
  _ret=$?
  _probe="$_tmp/lone.nix"
  if [ "$_ret" -eq 0 ]; then
    echo "FAIL: a launchd file capturing one stream must fail the policy"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! capture_reports "log capture pair: '$_probe' declares only one of StandardOutPath/StandardErrorPath; declare both or neither" "$_out"; then
    echo "FAIL: the launchd lone-stream report is not exact"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# The systemd family has its own wording. A pass that reported the launchd text
# for a systemd directive fails on the first assertion, one that dropped the
# systemd presence flags fails on the return code.
test_step14_capture_pair_lone_systemd_message_is_exact() {
  local _tmp _out _ret _probe
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" systemd-lone.nix
  _ret=$?
  _probe="$_tmp/systemd-lone.nix"
  if [ "$_ret" -eq 0 ]; then
    echo "FAIL: a systemd file capturing one stream must fail the policy"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! capture_reports "log capture pair: '$_probe' declares only one of StandardOutput/StandardError; declare both or neither" "$_out"; then
    echo "FAIL: the systemd lone-stream report is not exact"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if capture_reports "StandardOutPath/StandardErrorPath" "$_out"; then
    echo "FAIL: a systemd directive was reported with the launchd wording"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Flags are per file. One file captures the error stream only and the next
# captures the stdout stream only; a pass that carries the first file's flags
# into the second sees a pair and reports nothing for it.
test_step14_capture_pair_state_does_not_cross_files() {
  local _tmp _out _ret _first _second _count
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" lone.nix violations-lone.nix
  _ret=$?
  _first="$_tmp/lone.nix"
  _second="$_tmp/violations-lone.nix"
  _count=$(grep -cF 'declares only one of StandardOutPath/StandardErrorPath' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_count" -ne 2 ]; then
    echo "FAIL: expected both lone-stream files reported, got $_count"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if ! capture_reports "log capture pair: '$_first' declares only one" "$_out" ||
    ! capture_reports "log capture pair: '$_second' declares only one" "$_out"; then
    echo "FAIL: a lone-stream file was not reported under its own path"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Report order is per file and per rule, not line order: every discard report
# comes before every merged report, so a merged redirection above a discard is
# still reported second. This is the order the per-rule greps produced.
test_step14_capture_pair_reports_discard_before_merged() {
  local _tmp _out _ret _discard_at _merged_at
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" merged-above-discard.nix
  _ret=$?
  _discard_at=$(grep -nF 'discards a stream to /dev/null' "$_out" | head -1 | cut -d: -f1)
  _merged_at=$(grep -nF 'merges stdout and stderr' "$_out" | head -1 | cut -d: -f1)
  if [ "$_ret" -eq 0 ] || [ -z "$_discard_at" ] || [ -z "$_merged_at" ]; then
    echo "FAIL: the ordering fixture must report both a discard and a merge"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  if [ "$_discard_at" -ge "$_merged_at" ]; then
    echo "FAIL: the merged report came before the discard report"
    cat "$_out"
    rm -rf "$_tmp"
    rm -f "$_out"
    return 1
  fi
  rm -rf "$_tmp"
  rm -f "$_out"
  return 0
}

# Per-file accumulation does not carry into the next file: two violating files in
# one call report each hit once, not the first file's hits twice. A pass whose
# hit arrays are never cleared fails the first count.
test_step14_capture_pair_counts_reset_per_file() {
  local _tmp _out _ret _discards _merges
  _tmp=$(mktemp -d)
  _out=$(mktemp)
  capture_scan "$_out" "$_tmp" violations.nix violations.ps1
  _ret=$?
  _discards=$(grep -cF 'discards a stream to /dev/null' "$_out")
  _merges=$(grep -cF 'merges stdout and stderr' "$_out")
  if [ "$_ret" -eq 0 ] || [ "$_discards" -ne 2 ] || [ "$_merges" -ne 1 ]; then
    echo "FAIL: expected 2 discards and 1 merge, got $_discards and $_merges"
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
  test_step14_capture_pair_all_stream_positions_pass \
  test_step14_capture_pair_discard_message_is_exact \
  test_step14_capture_pair_merged_message_is_exact \
  test_step14_capture_pair_lone_launchd_message_is_exact \
  test_step14_capture_pair_lone_systemd_message_is_exact \
  test_step14_capture_pair_state_does_not_cross_files \
  test_step14_capture_pair_reports_discard_before_merged \
  test_step14_capture_pair_counts_reset_per_file \
  test_step14_removed_skip_constructs_detection \
  test_step14_config_method_unannotated_reference_fails \
  test_step14_config_method_case_variant_reference_fails \
  test_step14_config_method_empty_config_list_reports_counted_pass \
  test_step14_config_method_bracket_filename_resolves \
  test_step14_config_method_dot_prefixed_config_guard_fires \
  test_step14_config_method_parallel_reports_input_order \
  test_step14_config_method_same_line_annotation_passes \
  test_step14_config_method_preceding_annotation_passes \
  test_step14_config_method_window_is_10_lines \
  test_step14_config_method_reference_index_scan_count \
  test_step14_config_method_relative_tier_beats_basename \
  test_step14_config_method_template_tier_reference \
  test_step14_config_method_scoped_run_checks_whole_repo \
  test_step14_policy_scan_target_nested_basename \
  test_step14_naming_behavioral_positive \
  test_step14_naming_behavioral_negative \
  test_step14_naming_behavioral_exemption \
  test_step14_naming_behavioral_prefix \
  test_step14_naming_region_scopes_attrset_block \
  test_step14_naming_region_ends_at_closing_brace \
  test_step14_naming_nested_attrset_keeps_scanning \
  test_step14_naming_region_state_does_not_cross_files \
  test_step14_logging_behavioral_positive \
  test_step14_logging_behavioral_negative \
  test_step14_logging_behavioral_allowlist \
  test_step14_nix_file_structure_pattern1_detection \
  test_step14_nix_file_structure_pattern2_detection \
  test_step14_nix_file_structure_valid_passes \
  test_step14_capture_pair_behavioral_positive \
  test_step14_capture_pair_behavioral_negative \
  test_step14_envrc_ban_root_fails \
  test_step14_envrc_ban_nested_fails \
  test_step14_envrc_ban_clean_tree_passes \
  test_step14_envrc_ban_scoped_mode_fails \
  test_step14_envrc_ban_pruned_decoys_ignored; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
