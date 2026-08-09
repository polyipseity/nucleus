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
  if grep -Fq '/etc/nucleus/repo-root' "$FLAKE_NIX" &&
    grep -Fq '_repo_root/${scriptName}.sh' "$FLAKE_NIX" &&
    grep -Fq 'writeText "nucleus-repo-root"' "$FLAKE_NIX"; then
    assert_pass "flake nucleus wrappers prefer live checkout scripts"
  else
    assert_fail "flake nucleus wrappers prefer live checkout scripts" "missing live-script dispatch or marker fix"
  fi
}

test_apply_uses_pascal_case_flake_hosts
test_apply_prefers_live_checkout
test_scripts_apply_delegates_to_src
test_nucleus_wrappers_prefer_live_checkout
