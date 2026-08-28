#!/usr/bin/env bash
# Regression test: resolve_repo_root_target must resolve the live checkout via
# derive_repo_root, never a baked Nix store -source path. The 2026-08 bug echoed
# the eval-time store path, linking ~/dev/nucleus into the immutable store.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
DEV_REPOS_PROVISION_SH="$SCRIPT_DIR/../../src/scripts/lib/dev-repos-provision.sh"

# Source both libs in a clean subshell with an optional env prefix (space-separated
# VAR=value pairs). $0 is pinned so the derived command prefix stays deterministic.
_run_provision() {
  local env_prefix="$1" cmd="$2"
  bash -c "${env_prefix:-:}; devReposErrors=0; . \"\$1\"; . \"\$2\"; eval \"\$3\"" \
    nucleus-dev-repos-test "$LIB_SH" "$DEV_REPOS_PROVISION_SH" "$cmd"
}

# Case A: NUCLEUS_REPO_ROOT set to a temp dir wins.
test_env_var_wins() {
  local tmpdir out rc=0
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/src"
  printf 'marker\n' >"$tmpdir/src/flake.nix"
  out="$(_run_provision "NUCLEUS_REPO_ROOT=$tmpdir" 'resolve_repo_root_target' 2>&1)" || rc=$?
  out="$(printf '%s' "$out" | tr -d '\n')"
  # derive_repo_root canonicalizes via pwd -P (macOS /var -> /private/var).
  if [ "$rc" -eq 0 ] && [ -d "$out" ] && [ -f "$out/src/flake.nix" ]; then
    assert_pass "resolve_repo_root_target uses NUCLEUS_REPO_ROOT"
  else
    assert_fail "env-var" "rc=$rc output: $out"
  fi
  rm -rf "$tmpdir"
}

# Case B: with NUCLEUS_REPO_ROOT unset, the SYSTEM repo-root file is consulted.
test_system_file_fallback() {
  local tmpdir out rc=0
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/src"
  printf 'marker\n' >"$tmpdir/src/flake.nix"
  # Point derive_repo_root at a fake system file that records the temp dir.
  out="$(NUCLEUS_REPO_ROOT_SYSTEM_FILE="$tmpdir/system-repo-root" \
    NUCLEUS_REPO_ROOT_DIR="$tmpdir" \
    bash -c '
      printf "%s\n" "$NUCLEUS_REPO_ROOT_DIR" > "$NUCLEUS_REPO_ROOT_SYSTEM_FILE"
      devReposErrors=0
      . "'"$LIB_SH"'"
      . "'"$DEV_REPOS_PROVISION_SH"'"
      resolve_repo_root_target
    ' 2>&1)" || rc=$?
  rm -rf "$tmpdir"
  if [ "$rc" -eq 0 ] && [ -d "$out" ] && [ -f "$out/src/flake.nix" ]; then
    assert_pass "resolve_repo_root_target falls back to SYSTEM repo-root file"
  else
    assert_fail "system-file" "rc=$rc output: $out"
  fi
}

# Case C: with neither available, resolution fails hard (no fallback to store path).
test_hard_failure() {
  local out rc=0 sandbox
  sandbox="$(mktemp -d)"
  # Run from a non-git sandbox so the git rev-parse fallback cannot rescue
  # resolution; env + system file both point at nonexistent paths.
  out="$(cd -- "$sandbox" && NUCLEUS_REPO_ROOT="/nonexistent/nucleus-root" \
    NUCLEUS_REPO_ROOT_SYSTEM_FILE="/nonexistent/system-repo-root" \
    bash -c '
      devReposErrors=0
      . "'"$LIB_SH"'"
      . "'"$DEV_REPOS_PROVISION_SH"'"
      resolve_repo_root_target
    ' 2>&1)" && rc=0 || rc=$?
  rm -rf "$sandbox"
  if [ "$rc" -ne 0 ] && echo "$out" | grep -q "repo root not resolvable"; then
    assert_pass "resolve_repo_root_target fails hard when root is unresolvable"
  else
    assert_fail "hard-failure" "rc=$rc output: $out"
  fi
}

# ---- Run tests ----
section 1 "dev-repos-provision resolve_repo_root_target tests"
echo ""

test_env_var_wins
test_system_file_fallback
test_hard_failure
