#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLY_SH="$REPO_ROOT/src/scripts/apply.sh"
FLAKE_NIX="$REPO_ROOT/src/flake.nix"
SCRIPTS_APPLY="$REPO_ROOT/scripts/apply.sh"

test_apply_uses_pascal_case_flake_hosts() {
  if grep -Fq '#MacBook' "$APPLY_SH" && grep -Fq '#NixOS' "$APPLY_SH"; then
    assert_pass "apply.sh references PascalCase flake hosts"
  else
    assert_fail "apply.sh references PascalCase flake hosts" "expected #MacBook and #NixOS"
  fi
  if grep -Eq '#macbook|flake.*#nixos"' "$APPLY_SH"; then
    assert_fail "apply.sh must not reference lowercase flake hosts" "found legacy host attr"
  else
    assert_pass "apply.sh avoids lowercase flake hosts"
  fi
}

test_apply_prefers_live_checkout() {
  # shellcheck disable=SC2016 # reason: literal grep pattern for apply.sh source line
  if grep -Fq '_aar_live="$REPO_ROOT/src/scripts/apply.sh"' "$APPLY_SH"; then
    assert_pass "apply.sh re-execs live checkout when store snapshot is stale"
  else
    assert_fail "apply.sh re-execs live checkout when store snapshot is stale" "missing live re-exec guard"
  fi
}

test_scripts_apply_delegates_to_src() {
  if [ -x "$SCRIPTS_APPLY" ] || [ -f "$SCRIPTS_APPLY" ]; then
    if grep -Fq '../src/scripts/apply.sh' "$SCRIPTS_APPLY"; then
      assert_pass "scripts/apply.sh delegates to src/scripts/apply.sh"
    else
      assert_fail "scripts/apply.sh delegates to src/scripts/apply.sh" "missing exec target"
    fi
  else
    assert_fail "scripts/apply.sh exists" "file missing"
  fi
}

test_nucleus_wrappers_prefer_live_checkout() {
  # shellcheck disable=SC2016 # reason: literal grep pattern for flake.nix wrapper dispatch
  # Wrappers exec the store-bundled script directly (no repo-root detection, no
  # fallback). The repo-root marker itself is materialized by repo-root-file.nix
  # via a system activation script, not by flake.nix.
  if grep -Fq '_store_root/${scriptName}.sh' "$FLAKE_NIX" &&
    grep -Fq 'no repo-root detection, no fallback' "$FLAKE_NIX"; then
    assert_pass "flake nucleus wrappers prefer live checkout scripts"
  else
    assert_fail "flake nucleus wrappers prefer live checkout scripts" "missing live-script dispatch or marker fix"
  fi
}

test_apply_pins_flake_inputs() {
  if grep -Fq 'run_pin_flake_inputs' "$APPLY_SH"; then
    assert_pass "apply.sh defines run_pin_flake_inputs"
  else
    assert_fail "apply.sh defines run_pin_flake_inputs" "missing run_pin_flake_inputs function"
  fi
  if grep -Fq 'flakeInputs' "$APPLY_SH"; then
    assert_pass "apply.sh references flakeInputs output"
  else
    assert_fail "apply.sh references flakeInputs output" "missing flakeInputs reference"
  fi
  # Must be wired in all three OS branches (Darwin, NixOS, Linux HM).
  _branches=$(grep -c 'run_pin_flake_inputs' "$APPLY_SH")
  if [ "$_branches" -ge 3 ]; then
    assert_pass "apply.sh calls run_pin_flake_inputs in all OS branches"
  else
    assert_fail "apply.sh calls run_pin_flake_inputs in all OS branches" "found $_branches call sites, expected >=3"
  fi
}

test_apply_uses_pascal_case_flake_hosts
test_apply_prefers_live_checkout
test_scripts_apply_delegates_to_src
test_nucleus_wrappers_prefer_live_checkout
test_apply_pins_flake_inputs
