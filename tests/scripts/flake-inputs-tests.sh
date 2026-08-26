#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLAKE_NIX="$REPO_ROOT/src/flake.nix"

test_flake_inputs_output_references_all_inputs() {
  if grep -Fq 'flakeInputs' "$FLAKE_NIX"; then
    assert_pass "flake.nix defines flakeInputs output"
  else
    assert_fail "flake.nix defines flakeInputs output" "missing flakeInputs"
  fi

  _tmp_profile="$(mktemp -d)"
  # check-suppress:suppression_doc: build may fail if inputs missing; we assert on result, not abort.
  if NIX_CONFIG="min-free = 0" nix build "$REPO_ROOT/src#flakeInputs" --profile "$_tmp_profile/flake-inputs" -v 0 2>/tmp/flake-inputs-build.err; then
    _count=$(find "$_tmp_profile/flake-inputs" -maxdepth 1 -type l | wc -l | tr -d ' ')
    if [ "$_count" -eq 17 ]; then
      assert_pass "flakeInputs profile contains 17 input symlinks"
    else
      assert_fail "flakeInputs profile contains 17 input symlinks" "found $_count, expected 17"
    fi
  else
    assert_fail "flakeInputs builds" "$(head -5 /tmp/flake-inputs-build.err)"
  fi
  rm -rf "$_tmp_profile"
}

test_flake_inputs_output_references_all_inputs
