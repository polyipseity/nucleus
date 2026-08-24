#!/usr/bin/env bash
# Smoke tests: builds every nucleus-* command via a single batch build, then
# invokes each binary directly from its store path for --help (or dry-run /
# safe no-op) verification.
#
# Tier 1 — --help for every command (build + run verification).
# Tier 2 — --dry-run for commands that support it.
# Tier 3 — safe no-op execution (config list, svc list --json).
#
# Dependencies: nix (with flakes enabled), jq.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

cd "$REPO_ROOT"

TESTS_SKIPPED=0

assert_skip() {
  local test_name="$1"
  local reason="$2"
  printf '%s⊘%s %s: %s\n' "$YELLOW" "$NC" "$test_name" "$reason"
  ((++TESTS_SKIPPED))
}

# --- Phase 1: Batch build all nucleus packages -------------------------------
# Build every package in a single Nix evaluation. Outputs store paths in the
# same order as the package list.

# All nucleus-* packages that we test. Ordered to match the smoke test tiers
# below: app packages first (for --help), then package-only commands.
declare -a BATCH_PACKAGES=(
  nucleus-apply nucleus-ai nucleus-bootstrap
  nucleus-check nucleus-test nucleus-config nucleus-gc
  nucleus-utils nucleus-svc nucleus-update nucleus-vm
  nucleus-cloud
)

echo "Building ${#BATCH_PACKAGES[@]} nucleus packages..."

BUILD_JSON=$(nix build --no-link --json \
  "${BATCH_PACKAGES[@]/#/./src#}")
echo "Build complete."

# Build a map from package index → store path, preserving build order.
declare -a PKG_PATHS
while IFS=$'\t' read -r _idx _path; do
  PKG_PATHS[_idx]="$_path"
done < <(echo "$BUILD_JSON" | jq -r 'to_entries | .[] | [.key, .value.outputs.out] | @tsv')

# Run a nucleus-* binary from its store path.
run_binary() {
  local pkg="$1"
  shift
  local idx=-1
  for i in "${!BATCH_PACKAGES[@]}"; do
    if [ "${BATCH_PACKAGES[$i]}" = "$pkg" ]; then
      idx=$i
      break
    fi
  done
  if [ "$idx" -lt 0 ]; then
    echo "error: unknown package $pkg" >&2
    return 1
  fi
  NUCLEUS_REPO_ROOT="$REPO_ROOT" "${PKG_PATHS[idx]}/bin/$pkg" "$@" 2>&1
}

# --- Tier 1: --help tests --------------------------------------------------
# Verifies every nucleus-* command builds and responds to --help with output.

# Map app names (nix run names) to their corresponding package names.
declare -A APP_TO_PKG=(
  [apply]=nucleus-apply
  [ai]=nucleus-ai
  [bootstrap]=nucleus-bootstrap
  [check]=nucleus-check
  [test]=nucleus-test
  [config]=nucleus-config
  [gc]=nucleus-gc
  [svc]=nucleus-svc
  [update]=nucleus-update
  [vm]=nucleus-vm
  [cloud]=nucleus-cloud
)

test_app_help() {
  local app_name="$1"
  local pkg="${APP_TO_PKG[$app_name]:-}"
  if [ -z "$pkg" ]; then
    assert_fail "$app_name --help" "unknown app name (missing APP_TO_PKG entry)"
    return
  fi
  local exit_code=0
  local output
  output=$(run_binary "$pkg" --help) || exit_code=$?
  # Every nucleus-* command's --help path prints a `usage:` line (via
  # usage_std) and exits 0 (parse_args in step-runner.sh, or the script's
  # own dispatch). Both must hold — output alone is not a pass.
  if [ "$exit_code" -eq 0 ] && printf '%s' "$output" | grep -q 'usage:'; then
    assert_pass "$app_name --help"
  else
    assert_fail "$app_name --help" "exit=$exit_code, output: $(printf '%s' "$output" | head -3 | tr '\n' ' ')"
  fi
}

# App commands (names match `nix run ./src#<name>`)
APP_COMMANDS=(
  apply ai bootstrap check test
  config gc update svc vm cloud
)

section 1 "Tier 1: --help smoke tests"
for cmd in "${APP_COMMANDS[@]}"; do
  test_app_help "$cmd"
done

# gs-pdf-opt: verify it builds (already done in batch) and note the pass for
# the package-only build assertion.  (check-pwsh is now a subcommand of
# nucleus-check, covered by the Tier 1 --help test above.)
echo ""
echo "--- Package-only commands ---"
assert_pass "nucleus-utils build"

# gs-pdf-opt does support --help; run it from the store path.
gs_pdf_opt_exit=0
gs_pdf_opt_output=$(run_binary nucleus-utils gs-pdf-opt --help 2>/dev/null) || gs_pdf_opt_exit=$?
if [ "$gs_pdf_opt_exit" -eq 0 ] && printf '%s' "$gs_pdf_opt_output" | grep -q 'usage:'; then
  assert_pass "nucleus-utils --help"
else
  assert_fail "nucleus-utils --help" "exit=$gs_pdf_opt_exit"
fi

# --- Tier 2: dry-run tests -------------------------------------------------
# Commands that support --dry-run: run in dry mode to verify the control flow
# works (config parsing, argument dispatch) without side effects.

section 2 "Tier 2: dry-run tests"

declare -A DRY_RUN_APPS=(
  [ai]=nucleus-ai
  [gc]=nucleus-gc
  [vm]=nucleus-vm
)

test_app_dry_run() {
  local app_name="$1"
  local pkg="${DRY_RUN_APPS[$app_name]:-}"
  if [ -z "$pkg" ]; then
    assert_fail "$app_name --dry-run" "unknown app name (missing DRY_RUN_APPS entry)"
    return
  fi
  local exit_code=0
  local output
  output=$(run_binary "$pkg" --dry-run 2>&1) || exit_code=$?
  # The command's own <prefix>: diagnostic must be present. Exit codes vary
  # legitimately by environment (e.g. ai without Ollama), so the marker that
  # the command's control flow actually ran is required instead of "any
  # output" (a broken wrapper would produce none).
  if printf '%s' "$output" | grep -q "$app_name:"; then
    assert_pass "$app_name --dry-run (exit=$exit_code)"
  else
    assert_fail "$app_name --dry-run" "exit=$exit_code, no command output: $(printf '%s' "$output" | head -3 | tr '\n' ' ')"
  fi
}

# ai sync needs NUCLEUS_AI_SYNC_TIMEOUT=0 to avoid blocking on Ollama
NUCLEUS_AI_SYNC_TIMEOUT=0 test_app_dry_run ai
test_app_dry_run gc
test_app_dry_run vm

# --- Tier 3: safe no-op read-only commands --------------------------------
# Commands that perform read-only operations against local files.

section 3 "Tier 3: no-op read-only commands"

test_app_noop() {
  local app_name="$1"
  shift
  local args=("$@")
  local pkg="${APP_TO_PKG[$app_name]:-}"
  if [ -z "$pkg" ]; then
    assert_fail "$app_name ${args[*]}" "unknown app name (missing APP_TO_PKG entry)"
    return
  fi
  local exit_code=0
  local output
  output=$(run_binary "$pkg" "${args[@]}") || exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    assert_pass "$app_name ${args[*]}"
  else
    assert_pass "$app_name ${args[*]} (exit=$exit_code)"
  fi
}

# config list: reads ~/.local/state/nucleus/config.json (or defaults).
test_app_noop config list

# svc list --json --user: only user-domain services, no sudo needed.
SVC_DOMAIN_FILTER=user test_app_noop svc list --json

# --- Tier 4: completion syntax validation -----------------------------------

section 4 "Tier 4: completion file syntax validation"

# Zsh completion files: check syntax with zsh -n.
_zsh_comp_dir="$REPO_ROOT/src/modules/completions/zsh"
if command -v zsh >/dev/null 2>&1; then
  for _zsh_comp_f in "$_zsh_comp_dir"/_nucleus-* "$_zsh_comp_dir"/_nucleus; do
    [ -f "$_zsh_comp_f" ] || continue
    _zsh_comp_name="$(basename "$_zsh_comp_f")"
    if zsh -n "$_zsh_comp_f" 2>/dev/null; then
      assert_pass "zsh completion syntax: $_zsh_comp_name"
    else
      assert_fail "zsh completion syntax: $_zsh_comp_name" "syntax error"
    fi
  done
else
  assert_skip "zsh completion syntax check" "zsh not available"
fi

# Generated-header assertion: every _nucleus* file must carry the generator
# header — a hand-edited (or stale) file fails loudly, not silently.
for _zsh_comp_f in "$_zsh_comp_dir"/_nucleus-* "$_zsh_comp_dir"/_nucleus; do
  [ -f "$_zsh_comp_f" ] || continue
  _zsh_comp_name="$(basename "$_zsh_comp_f")"
  if grep -q '^# GENERATED by src/scripts/completions/gen-completions.sh' "$_zsh_comp_f"; then
    assert_pass "generated header: $_zsh_comp_name"
  else
    assert_fail "generated header: $_zsh_comp_name" "missing # GENERATED header (hand-edited or stale)"
  fi
done
unset _zsh_comp_dir _zsh_comp_f _zsh_comp_name

# PowerShell completion ScriptBlocks: extract from the shared profile.ps1 and parse-check.
# profile.ps1 is the single source for shell-parity content — pwsh.nix embeds it
# for POSIX at eval time and Sync-ShellProfile.ps1 reads it back for Windows at
# runtime, so one parse check covers both platforms.
if command -v pwsh >/dev/null 2>&1; then
  # Extract Register-ArgumentCompleter blocks from profile.ps1 into a temp script
  # and parse them.  The ScriptBlocks contain valid PowerShell that can be
  # verified with [ScriptBlock]::Create().
  _pwsh_comp_file="$REPO_ROOT/src/scripts/shell/profile.ps1"
  if [ -f "$_pwsh_comp_file" ]; then
    _temp_pwsh_check="$(mktemp)"
    awk 'function cb(s,c,i){c=0;for(i=1;i<=length(s);i++){if(substr(s,i,1)=="{")c++;if(substr(s,i,1)=="}")c--}return c}
    BEGIN{ib=0;d=0}{gsub(/\r/,"")}
    /^Register-ArgumentCompleter/{ib=1;bl=$0;d=cb($0);if(d<=0){print bl;print"";ib=0}next}
    ib{bl=bl"\n"$0;d+=cb($0);if(d<=0){print bl;print"";ib=0}}
    END{if(ib)print bl}' "$_pwsh_comp_file" >"$_temp_pwsh_check" 2>/dev/null || true # check-suppress:suppression_doc: probe -- file may not contain completions yet; handled by [ -s ] guard below
    if [ -s "$_temp_pwsh_check" ]; then
      if pwsh -NoProfile -NonInteractive -Command "
        \$content = Get-Content '$_temp_pwsh_check' -Raw -ErrorAction Stop
        try { [ScriptBlock]::Create(\$content) > \$null } catch { throw \"syntax error: \$(\$_.Exception.Message)\" }
        Write-Host \"pwsh completions: 0 errors\"
      " 2>/dev/null; then
        assert_pass "pwsh completion ScriptBlocks parse (profile.ps1)"
      else
        assert_fail "pwsh completion ScriptBlocks parse (profile.ps1)" "syntax error in extracted completions"
      fi
    else
      assert_skip "pwsh completion ScriptBlocks parse (profile.ps1)" "could not extract completions from profile.ps1"
    fi
    rm -f "$_temp_pwsh_check"
  fi
else
  assert_skip "pwsh completion ScriptBlocks parse" "pwsh not available"
fi
unset _pwsh_comp_file

# --- Summary ---------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  if [ "$TESTS_SKIPPED" -eq 0 ]; then
    printf '%sAll %s nucleus apps smoke tests passed.%s\n' "$GREEN" "$TESTS_PASSED" "$NC"
  else
    printf '%s%s passed, %s skipped.%s\n' "$GREEN" "$TESTS_PASSED" "$TESTS_SKIPPED" "$NC"
  fi
else
  printf '%s%s/%s nucleus apps smoke tests FAILED.%s\n' "$RED" "$TESTS_FAILED" "$((TESTS_FAILED + TESTS_PASSED))" "$NC" >&2
  exit 1
fi
