#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 23 legacy-token-syntax must flag legacy {{TOKEN}} placeholders and accept double-underscore tokens

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/23-legacy-token-syntax.sh"

# Run the step's check function in a subshell; returns its exit code.
run_step23() {
  # shellcheck source=../../../src/scripts/checks/check-steps/23-legacy-token-syntax.sh
  ( . "$TEST_FILE"; run_23_legacy_token_syntax "$@" >/dev/null 2>&1 )
}

test_step23_has_register_step() {
  if grep -q 'register_step "legacy-token-syntax" 23' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should register as legacy-token-syntax"
  return 1
}

test_step23_has_legacy_pattern() {
  # Matches: grep -nH -E '\{\{[A-Za-z_]'
  if grep -qF '\{\{[A-Za-z_]' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should detect legacy {{TOKEN}} placeholder syntax"
  return 1
}

test_step23_has_category_c_ref() {
  if grep -q 'allow-and-deny-lists.instructions.md#C6' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should register its self-exclusion in allow-and-deny-lists Category C"
  return 1
}

test_step23_has_self_exclusion() {
  # Matches: _s23_self_sh="$(basename "${BASH_SOURCE[0]}")"
  if grep -q 'basename.*BASH_SOURCE' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should exclude its own source file"
  return 1
}

test_step23_scopes_production_dirs() {
  # Matches: case "$_f" in src/*|scripts/*)
  if grep -qF 'src/*|scripts/*' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should only scan src/ and scripts/ in scoped mode"
  return 1
}

test_step23_scopes_code_extensions() {
  # Matches: *.ps1|*.sh|*.zsh|*.nix|*.yml
  if grep -qF '*.ps1|*.sh|*.zsh|*.nix|*.yml' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should scan only code extensions (.ps1 .sh .zsh .nix .yml)"
  return 1
}

test_step23_uses_gitignore_filter() {
  if grep -q 'filter_gitignored' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 23 should apply the gitignore filter to its file list"
  return 1
}

test_step23_behavioral_rejects_legacy_token() {
  # Behavioral: a fixture with {{X}} must fail the check.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'value = {{DEPLOY_ID}}\n' > "$_tmpdir/src/fixture.ps1"
  _exit_code=0
  run_step23 true "$_tmpdir" "src/fixture.ps1" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 23 should reject {{DEPLOY_ID}} in scoped mode"
  return 1
}

test_step23_behavioral_accepts_double_underscore() {
  # Behavioral: a fixture with a double-underscore token must pass the check.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'value = __DEPLOY_ID__\n' > "$_tmpdir/src/fixture.ps1"
  _exit_code=0
  run_step23 true "$_tmpdir" "src/fixture.ps1" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -eq 0 ]; then
    return 0
  fi
  echo "FAIL: step 23 should accept __DEPLOY_ID__ in scoped mode"
  return 1
}

test_step23_behavioral_rejects_full_mode() {
  # Behavioral: full mode must also flag a legacy token in src/.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'value = {{LANE_SCOPE}}\n' > "$_tmpdir/src/fixture.nix"
  _exit_code=0
  run_step23 false "$_tmpdir" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 23 should reject {{LANE_SCOPE}} in full mode"
  return 1
}

test_step23_behavioral_ignores_github_actions() {
  # Behavioral: GitHub Actions ${{ }} expressions must NOT be flagged.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  cat > "$_tmpdir/src/fixture.yml" <<'EOF'
run: echo ${{ github.ref }}
EOF
  _exit_code=0
  run_step23 true "$_tmpdir" "src/fixture.yml" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -eq 0 ]; then
    return 0
  fi
  echo "FAIL: step 23 should ignore GitHub Actions \${{ }} expressions"
  return 1
}

if [ "$#" -eq 0 ] || [ "$1" = "test_step23_has_register_step" ]; then
  test_step23_has_register_step || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_has_legacy_pattern" ]; then
  test_step23_has_legacy_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_has_category_c_ref" ]; then
  test_step23_has_category_c_ref || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_has_self_exclusion" ]; then
  test_step23_has_self_exclusion || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_scopes_production_dirs" ]; then
  test_step23_scopes_production_dirs || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_scopes_code_extensions" ]; then
  test_step23_scopes_code_extensions || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_uses_gitignore_filter" ]; then
  test_step23_uses_gitignore_filter || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_behavioral_rejects_legacy_token" ]; then
  test_step23_behavioral_rejects_legacy_token || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_behavioral_accepts_double_underscore" ]; then
  test_step23_behavioral_accepts_double_underscore || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_behavioral_rejects_full_mode" ]; then
  test_step23_behavioral_rejects_full_mode || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step23_behavioral_ignores_github_actions" ]; then
  test_step23_behavioral_ignores_github_actions || exit 1
fi
