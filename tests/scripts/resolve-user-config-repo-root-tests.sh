#!/usr/bin/env bash
# Tests for src/scripts/lib/resolve-user-config.sh repo-root resolution.
#
# The resolver must delegate to derive_repo_root(): a Nix store snapshot can
# never be used as the repo root, and the system repo-root file is the fallback
# when NUCLEUS_REPO_ROOT is unset (activation scripts run under `env -i`).
#
# Run with: bash tests/scripts/resolve-user-config-repo-root-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

RESOLVER="$SCRIPT_DIR/../../src/scripts/lib/resolve-user-config.sh"
readonly RESOLVER

# _rrc_make_live_checkout DIR — fake live checkout that derive_repo_root accepts
# (src/flake.nix marker) plus an agents/skills overlay entry.
_rrc_make_live_checkout() {
  mkdir -p "$1/src/users/default/agents/skills"
  printf 'marker\n' >"$1/src/flake.nix"
}

# _rrc_resolve [ENV...] — resolve the agents/skills overlay entry for test-user
# in a fresh shell, printing only stdout.
_rrc_resolve() {
  env "$@" bash -c '. "'"$RESOLVER"'"; resolve_user_config_first_level_entry test-user agents skills' 2>/dev/null
}

test_store_path_env_falls_back_to_system_file() {
  local tmp live out rc=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  live="$tmp/live"
  _rrc_make_live_checkout "$live"
  printf '%s\n' "$live" >"$tmp/system-repo-root"
  out="$(_rrc_resolve NUCLEUS_REPO_ROOT=/nix/store/nonexistent-source \
    NUCLEUS_REPO_ROOT_SYSTEM_FILE="$tmp/system-repo-root")" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$live/src/users/default/agents/skills" ]; then
    assert_pass "store-path NUCLEUS_REPO_ROOT falls back to the system repo-root file"
  else
    assert_fail "store-path fallback" "rc=$rc output: $out"
  fi
}

test_live_env_var_is_still_used() {
  local tmp live canonical out rc=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  live="$tmp/live"
  _rrc_make_live_checkout "$live"
  # derive_repo_root canonicalizes the env var path (macOS /var -> /private/var).
  canonical="$(cd "$live" && pwd -P)"
  out="$(_rrc_resolve -u NUCLEUS_REPO_ROOT_SYSTEM_FILE NUCLEUS_REPO_ROOT="$live")" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$canonical/src/users/default/agents/skills" ]; then
    assert_pass "live NUCLEUS_REPO_ROOT is still honoured"
  else
    assert_fail "live env var" "rc=$rc output: $out expected: $canonical/src/users/default/agents/skills"
  fi
}

test_unset_env_var_uses_system_file_and_never_store_path() {
  local tmp live out rc=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  live="$tmp/live"
  _rrc_make_live_checkout "$live"
  printf '%s\n' "$live" >"$tmp/system-repo-root"
  out="$(_rrc_resolve -u NUCLEUS_REPO_ROOT NUCLEUS_REPO_ROOT_SYSTEM_FILE="$tmp/system-repo-root")" || rc=$?
  case "$out" in
  /nix/store/*)
    assert_fail "store path never returned" "output: $out"
    return 0
    ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$out" = "$live/src/users/default/agents/skills" ]; then
    assert_pass "unset NUCLEUS_REPO_ROOT resolves via the system repo-root file"
  else
    assert_fail "system-file resolution" "rc=$rc output: $out"
  fi
}

test_store_path_env_falls_back_to_system_file
test_live_env_var_is_still_used
test_unset_env_var_uses_system_file_and_never_store_path

finish_tests
