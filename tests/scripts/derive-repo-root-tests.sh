#!/usr/bin/env bash
# Test: derive_repo_root() rejects Nix store paths as NUCLEUS_REPO_ROOT values.
# Defense-in-depth against the 2026-09 gui-env LaunchAgent store-path poisoning.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"

# Case A: non-existent /nix/store/ path falls through to system file.
test_store_path_falls_through() {
  local tmpdir out rc=0
  tmpdir="$(mktemp -d)"
  local live_checkout="$tmpdir/live"
  mkdir -p "$live_checkout/src"
  printf 'marker\n' >"$live_checkout/src/flake.nix"
  out="$(NUCLEUS_REPO_ROOT=/nix/store/nonexistent-source \
    NUCLEUS_REPO_ROOT_SYSTEM_FILE="$tmpdir/system-repo-root" \
    bash -c '
      printf "%s\n" "'"$live_checkout"'" > "'"$tmpdir/system-repo-root"'"
      . "'"$LIB_SH"'"
      derive_repo_root
    ' 2>&1)" || rc=$?
  rm -rf "$tmpdir"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "$live_checkout"; then
    assert_pass "derive_repo_root falls through non-existent store path to system file"
  else
    assert_fail "store-path-fallthrough" "rc=$rc output: $out"
  fi
}

# Case B: store-path env var + no system file → falls through to SCRIPT_DIR.
test_store_path_falls_through_to_script_dir() {
  local out rc=0
  # SCRIPT_DIR points to the scripts/lib directory inside the live repo;
  # derive_repo_root should walk up from there.
  out="$(NUCLEUS_REPO_ROOT=/nix/store/nonexistent-source \
    NUCLEUS_REPO_ROOT_SYSTEM_FILE="$PWD/nonexistent-system-repo-root" \
    SCRIPT_DIR="$(cd "$SCRIPT_DIR/../../src/scripts/lib" && pwd -P)" \
    bash -c '
      . "'"$LIB_SH"'"
      derive_repo_root
    ' 2>&1)" || rc=$?
  local expected
  expected="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
  if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
    assert_pass "derive_repo_root falls through to SCRIPT_DIR when env var is store path"
  else
    assert_fail "store-path-script-dir" "rc=$rc output: $out expected: $expected"
  fi
}

# Case C: NUCLEUS_REPO_ROOT set to a normal (non-store) path still works.
test_normal_env_var_accepted() {
  local tmpdir out rc=0
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/src"
  printf 'marker\n' >"$tmpdir/src/flake.nix"
  out="$(NUCLEUS_REPO_ROOT="$tmpdir" bash -c '
      . "'"$LIB_SH"'"
      derive_repo_root
    ' 2>&1)" || rc=$?
  # derive_repo_root canonicalizes via pwd -P (macOS /var -> /private/var).
  local canonical
  canonical="$(cd "$tmpdir" && pwd -P)"
  rm -rf "$tmpdir"
  if [ "$rc" -eq 0 ] && [ "$out" = "$canonical" ]; then
    assert_pass "derive_repo_root accepts normal env var path"
  else
    assert_fail "normal-env-var" "rc=$rc output: $out expected: $canonical"
  fi
}

test_store_path_falls_through
test_store_path_falls_through_to_script_dir
test_normal_env_var_accepted

# Summary
if [ "$TESTS_FAILED" -gt 0 ]; then
  printf '\n%s%d failed%s\n' "${RED:-}" "$TESTS_FAILED" "${NC:-}"
  exit 1
fi
printf '\n%s%d passed%s\n' "${GREEN:-}" "$TESTS_PASSED" "${NC:-}"
