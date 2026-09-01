#!/usr/bin/env bash
# Behavioral tests for src/scripts/lib/env-catalog.sh: ensure_env_catalog
# generates a valid (possibly empty) env-catalog.generated.nix when system.yml
# is absent, is idempotent, and never clobbers a pre-set NUCLEUS_CATALOG_PATH.
#
# Run with: bash tests/scripts/env-catalog-tests.sh

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/env-catalog.sh
. "$SCRIPT_DIR/../../src/scripts/lib/env-catalog.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# make_isolated_repo <out-dir> [with-system-yml]
# Create a temp repo root with src/modules/ai/env-catalog.schema.json present
# and optionally src/secrets/system.yml. Print the repo root.
mkdir -p "$REPO_ROOT/src/modules/ai" "$REPO_ROOT/src/secrets"
make_isolated_repo() {
  local _dir="$1" _with_yml="${2:-}"
  mkdir -p "$_dir/src/modules/ai" "$_dir/src/secrets"
  cp "$REPO_ROOT/src/modules/ai/env-catalog.schema.json" "$_dir/src/modules/ai/env-catalog.schema.json"
  if [ -n "$_with_yml" ]; then
    cp "$REPO_ROOT/src/secrets/system.yml" "$_dir/src/secrets/system.yml"
  fi
  printf '%s\n' "$_dir"
}

# nix_keys <nix-path>
# Print the number of keys in an env-catalog.generated.nix via nix-instantiate.
nix_keys() {
  nix-instantiate --eval --expr "builtins.length (import \"$1\").keys" 2>/dev/null
}

test_empty_catalog_when_system_yml_absent() {
  local _repo _home _catalog
  _repo="$(make_isolated_repo "$(mktemp -d)" "")"
  _home="$(mktemp -d)"
  HOME="$_home"
  REPO_ROOT="$_repo"
  unset NUCLEUS_CATALOG_PATH

  ensure_env_catalog
  _catalog="${NUCLEUS_CATALOG_PATH:-}"

  if [ -n "$_catalog" ] && [ -f "$_catalog" ] && [ "$(nix_keys "$_catalog")" = "0" ]; then
    assert_pass "empty catalog generated when system.yml absent"
  else
    assert_fail "empty catalog generated when system.yml absent" \
      "catalog='$_catalog' keys=$(nix_keys "$_catalog" 2>/dev/null)"
  fi
}

test_idempotent_regeneration() {
  local _repo _home _catalog _before
  _repo="$(make_isolated_repo "$(mktemp -d)" "")"
  _home="$(mktemp -d)"
  HOME="$_home"
  REPO_ROOT="$_repo"
  unset NUCLEUS_CATALOG_PATH

  ensure_env_catalog
  _catalog="${NUCLEUS_CATALOG_PATH}"
  _before="$(nix_keys "$_catalog")"

  # Second call must skip regeneration (path unchanged, content identical).
  ensure_env_catalog
  if [ "${NUCLEUS_CATALOG_PATH:-}" = "$_catalog" ] &&
    [ "$(nix_keys "$_catalog")" = "$_before" ]; then
    assert_pass "ensure_env_catalog is idempotent"
  else
    assert_fail "ensure_env_catalog is idempotent" "path or content changed on second call"
  fi
}

test_preset_env_not_clobbered() {
  local _repo _home _preset
  _repo="$(make_isolated_repo "$(mktemp -d)" "")"
  _home="$(mktemp -d)"
  HOME="$_home"
  REPO_ROOT="$_repo"

  # Pre-set NUCLEUS_CATALOG_PATH to an existing, distinct .nix artifact.
  _preset="$(mktemp -p "$_home" preset.XXXXXX.nix)"
  printf '%s\n' '{ keys = [ { name = "preset"; envVar = "PRESET"; } ]; }' >"$_preset"
  NUCLEUS_CATALOG_PATH="$_preset"
  export NUCLEUS_CATALOG_PATH

  ensure_env_catalog

  if [ "${NUCLEUS_CATALOG_PATH:-}" = "$_preset" ] &&
    [ "$(nix_keys "$_preset")" = "1" ]; then
    assert_pass "pre-set NUCLEUS_CATALOG_PATH is not clobbered"
  else
    assert_fail "pre-set NUCLEUS_CATALOG_PATH is not clobbered" \
      "path=${NUCLEUS_CATALOG_PATH:-} keys=$(nix_keys "$_preset" 2>/dev/null)"
  fi
}

test_empty_catalog_when_system_yml_absent
test_idempotent_regeneration
test_preset_env_not_clobbered

echo "--- env-catalog tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
exit "$TESTS_FAILED"
