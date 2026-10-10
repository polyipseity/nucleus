#!/usr/bin/env bash
# Test: the init.zsh stale nix-env guard warns once when a shell inherited
# garbage-collected nix store paths, and stays silent otherwise.
#
# The guard protects long-lived shells whose devShell closure was freed by
# nix-store --gc: they still export NIX_CC/SDKROOT/DEVELOPER_DIR pointing into
# /nix/store, and every link dies with "library not found for -lSystem". The
# suite substitutes init.zsh's build-time tokens the way shell.nix does, then
# sources the result under zsh -f with a controlled environment: the warning
# is the observable behavior, so the assertions target stderr.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command zsh "zsh sources src/scripts/shell/init.zsh"
require_command sed "token substitution mirrors shell.nix replaceStrings"

_sls_phrase="inherited nix store paths that no longer exist"
_sls_dead="/nix/store/00000000000000000000000000000000-dead"
# /nix/store itself is a real store-prefixed path that always exists on a
# nix host, so it exercises the live-path branch without depending on a
# specific store entry.
_sls_live="/nix/store"

_sls_tmp="$(mktemp -d)"
trap 'rm -rf "$_sls_tmp"' EXIT
_sls_home="$_sls_tmp/home"
mkdir -p "$_sls_home"

# Substitute every build-time token the way src/modules/shell/default.nix
# does, with benign values: a no-op statement for the injected check lines,
# never-present paths for the devin probe and the default tools root. Tokens
# reach the test source un-substituted otherwise, and a bare token line would
# abort sourcing before the guard ever runs.
_sls_init="$_sls_tmp/init.zsh"
sed \
  -e 's/__AGENT_ENV_VAR_CHECKS__/:/' \
  -e 's|__AGENT_DEVIN_PATH__|/nonexistent-nucleus-devin|' \
  -e 's|__DEFAULT_DEV_TOOLS_PATH__|/nonexistent-nucleus-default-dev-tools|' \
  -e 's/__MACOS_ICLOUD_HOOKS__/:/' \
  "$REPO_ROOT/src/scripts/shell/init.zsh" >"$_sls_init"

# A token the substitution missed would make the suite exercise a broken file,
# so pin that the substituted copy holds none.
if grep -Eq '__[A-Z][A-Z0-9_]*__' "$_sls_init"; then
  assert_fail "token substitution leaves no __TOKEN__ behind" \
    "unsubstituted: $(grep -Eo '__[A-Z][A-Z0-9_]*__' "$_sls_init" | sort -u | tr '\n' ' ')"
  finish_tests
fi
assert_pass "token substitution leaves no __TOKEN__ behind"

# The driver autoloads compinit the way an interactive zsh does: zsh -f skips
# the rc files that normally register the autoload, so sourcing init.zsh bare
# would die with "command not found: compinit" before reaching the guard.
_sls_driver="$_sls_tmp/driver.zsh"
printf 'autoload -Uz compinit\n. "%s"\n' "$_sls_init" >"$_sls_driver"

# run_init_case ERRFILE [VAR=VALUE ...]: source the substituted init under
# zsh -f from inside the temp dir (keeping the prek hook away from a real
# repo) with NIX_CC/SDKROOT/DEVELOPER_DIR cleared first, then whatever the
# case assigns. HOME points at the temp dir so compinit writes nothing real.
run_init_case() { # <err-file> [VAR=VALUE ...]
  local _err="$1"
  shift
  (
    cd "$_sls_tmp" || exit 1
    env -u NIX_CC -u SDKROOT -u DEVELOPER_DIR "$@" HOME="$_sls_home" \
      zsh -f "$_sls_driver" </dev/null >/dev/null 2>"$_err"
  )
}

assert_warns() { # <label> <err-file>
  if grep -qF "$_sls_phrase" "$2"; then
    assert_pass "$1"
  else
    assert_fail "$1" "warning missing; stderr: $(tr '\n' ' ' <"$2")"
  fi
}

assert_no_warn() { # <label> <err-file>
  if grep -qF "$_sls_phrase" "$2"; then
    assert_fail "$1" "unexpected warning; stderr: $(tr '\n' ' ' <"$2")"
  else
    assert_pass "$1"
  fi
}

_err="$_sls_tmp/err.txt"

# A dead NIX_CC is the failing-cargo case: warn, and name the dead path.
run_init_case "$_err" "NIX_CC=$_sls_dead"
assert_warns "dead NIX_CC warns" "$_err"
if grep -qF "$_sls_dead" "$_err"; then
  assert_pass "dead NIX_CC warning names the dead path"
else
  assert_fail "dead NIX_CC warning names the dead path" \
    "stderr: $(tr '\n' ' ' <"$_err")"
fi

# The guard must survive re-sourcing without repeating itself.
_sls_twice="$_sls_tmp/twice.zsh"
printf 'autoload -Uz compinit\n. "%s"\n. "%s"\n' "$_sls_init" "$_sls_init" >"$_sls_twice"
(
  cd "$_sls_tmp" || exit 1
  env -u SDKROOT -u DEVELOPER_DIR "NIX_CC=$_sls_dead" HOME="$_sls_home" \
    zsh -f "$_sls_twice" </dev/null >/dev/null 2>"$_err"
)
_warn_count="$(grep -cF "$_sls_phrase" "$_err" || true)"
if [ "$_warn_count" -eq 1 ]; then
  assert_pass "re-sourcing the init warns exactly once"
else
  assert_fail "re-sourcing the init warns exactly once" "warned $_warn_count times"
fi

# No inherited nix vars: silence.
run_init_case "$_err"
assert_no_warn "all nix vars unset: no warning" "$_err"

# A live store path: silence. Proves the guard checks existence, not the prefix.
run_init_case "$_err" "NIX_CC=$_sls_live"
assert_no_warn "live NIX_CC: no warning" "$_err"

# Dead DEVELOPER_DIR: warns, so the guard is not NIX_CC-only.
run_init_case "$_err" "DEVELOPER_DIR=$_sls_dead"
assert_warns "dead DEVELOPER_DIR warns" "$_err"

# Dead SDKROOT: the third variable, same expectation.
run_init_case "$_err" "SDKROOT=$_sls_dead"
assert_warns "dead SDKROOT warns" "$_err"

finish_tests
