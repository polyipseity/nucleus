#!/usr/bin/env bash
# WHY: the delegation member executes scripts/apply.sh against a stub copy of
# src/scripts/apply.sh, because delegation is observable behavior. The other
# members read source text: they check structural invariants of
# src/scripts/apply.sh and src/flake.nix that have no runtime surface in the
# check environment, since running a real apply would rebuild and activate the
# host. Each pattern is a code token whose absence would break runtime behavior.
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
  if [ ! -f "$SCRIPTS_APPLY" ]; then
    assert_fail "scripts/apply.sh exists" "file missing"
    return
  fi
  # Executed, not grepped: a copy of scripts/apply.sh has to run the stub
  # src/scripts/apply.sh that sits beside it and hand over argv and exit status.
  local _tmp _rc=0 _argv=""
  _tmp="$(mktemp -d)"
  mkdir -p "$_tmp/bin" "$_tmp/src/scripts"
  cp "$SCRIPTS_APPLY" "$_tmp/bin/apply.sh"
  cat >"$_tmp/src/scripts/apply.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$APPLY_STUB_LOG"
exit 42
STUB
  chmod +x "$_tmp/bin/apply.sh" "$_tmp/src/scripts/apply.sh"
  APPLY_STUB_LOG="$_tmp/stub-argv" bash "$_tmp/bin/apply.sh" first second >/dev/null 2>&1 || _rc=$?
  if [ -f "$_tmp/stub-argv" ]; then
    _argv="$(cat "$_tmp/stub-argv")"
  fi
  rm -rf "$_tmp"
  if [ "$_rc" -eq 42 ] && [ "$_argv" = $'first\nsecond' ]; then
    assert_pass "scripts/apply.sh delegates to src/scripts/apply.sh"
  else
    assert_fail "scripts/apply.sh delegates to src/scripts/apply.sh" "rc=$_rc argv=[$_argv]"
  fi
}

test_nucleus_wrappers_prefer_live_checkout() {
  # shellcheck disable=SC2016 # reason: literal grep pattern for flake.nix wrapper dispatch
  # Wrappers exec the store-bundled script directly (no repo-root detection, no
  # fallback). The live repo root is recorded by scripts/apply.sh at the SYSTEM
  # root, not by flake.nix.
  if grep -Fq '_store_root/${scriptName}.sh' "$FLAKE_NIX"; then
    assert_pass "flake nucleus wrappers prefer live checkout scripts"
  else
    assert_fail "flake nucleus wrappers prefer live checkout scripts" "missing live-script dispatch"
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
}

test_apply_prebuild_fails_hard() {
  # Pre-build and system activation build the same derivation. If pre-build fails,
  # the activation would fail with the same error, continuing wastes time.
  if grep -q 'die -l pre-build' "$APPLY_SH" && ! grep -q 'warn -l pre-build.*proceeding' "$APPLY_SH"; then
    assert_pass "apply.sh pre-build uses die on failure"
  else
    assert_fail "apply.sh pre-build uses die on failure" "expected die, found warn-and-continue"
  fi
}

test_apply_uses_pascal_case_flake_hosts
test_apply_prefers_live_checkout
test_scripts_apply_delegates_to_src
test_nucleus_wrappers_prefer_live_checkout
test_apply_pins_flake_inputs
test_apply_prebuild_fails_hard
finish_tests
