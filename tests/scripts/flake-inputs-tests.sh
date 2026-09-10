#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLAKE_NIX="$REPO_ROOT/src/flake.nix"

test_flake_inputs_output_covers_all_inputs() {
  if grep -Fq 'flakeInputs' "$FLAKE_NIX"; then
    assert_pass "flake.nix defines flakeInputs output"
  else
    assert_fail "flake.nix defines flakeInputs output" "missing flakeInputs"
  fi

  _tmp_dir="$(mktemp -d)"
  # check-suppress:suppression_doc: build may fail if inputs missing; we assert on result, not abort.
  if _out="$(NIX_CONFIG="min-free = 0" nix build "$REPO_ROOT/src#flakeInputs" --no-link --print-out-paths 2>"$_tmp_dir/build.err")"; then
    # Compare input names rather than a fixed total: the output also carries
    # transitive entries (brew-src, nixlib), and a hard-coded count silently rots
    # as soon as an input is added. LC_ALL=C keeps comm's collation consistent on
    # both sides. The store path is used directly because --profile adds a chain
    # of relative links that find cannot follow portably.
    jq -r '.nodes.root.inputs | keys[]' "$REPO_ROOT/src/flake.lock" | LC_ALL=C sort >"$_tmp_dir/declared"
    find "$_out" -maxdepth 1 -type l -exec basename {} \; | LC_ALL=C sort >"$_tmp_dir/built"
    _missing="$(comm -23 "$_tmp_dir/declared" "$_tmp_dir/built" | tr '\n' ' ')"
    if [ -z "$_missing" ]; then
      assert_pass "flakeInputs covers every input declared in flake.lock"
    else
      assert_fail "flakeInputs covers every input declared in flake.lock" "missing: $_missing"
    fi
  else
    assert_fail "flakeInputs builds" "$(head -5 "$_tmp_dir/build.err")"
  fi
  rm -rf "$_tmp_dir"
}

test_flake_inputs_output_covers_all_inputs
finish_tests
