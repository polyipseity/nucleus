#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 14 repository-policy must enforce dummy-key registry uniformity

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/14-repository-policy.sh"
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
  test_step14_naming_behavioral_prefix; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
