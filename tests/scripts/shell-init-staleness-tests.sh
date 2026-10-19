#!/usr/bin/env bash
# Test: the init.zsh stale nix-env scrubber drops garbage-collected store
# paths from inherited env, reports exactly what it dropped, and stays silent
# when nothing is dead.
#
# The scrubber protects long-lived shells whose devShell closure was freed by
# nix-store --gc: they still export NIX_CC/SDKROOT and friends pointing into
# /nix/store, and every link then dies with "library not found for -lSystem".
# The suite substitutes init.zsh's build-time tokens the way shell.nix does,
# then sources the result under zsh -f with a controlled environment: the
# report on stderr and the post-source variable state on stdout are the
# observable behavior, so the assertions target both.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command zsh "zsh sources src/scripts/shell/init.zsh"
require_command sed "token substitution mirrors shell.nix replaceStrings"

_sls_prefix="this shell inherited nix store paths that no longer exist; dropped: "
_sls_remedy="those devShell tools are gone; re-enter the devShell (direnv reload, or exit and re-enter) to restore them."
# 32-char store hash of all zeros cannot name a real store entry, so the path
# is dead by construction without depending on GC state.
_sls_dead="/nix/store/00000000000000000000000000000000-dead"
_sls_dead_sub="$_sls_dead/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
# /nix/store itself is a real store-prefixed path that always exists on a
# nix host, and its first segment is not a store hash, so it exercises the
# live/non-hash branch without depending on a specific store entry.
_sls_live="/nix/store"
# Every case runs under this live PATH: the test process may itself inherit
# GC'd store entries from its parent shell, and ambient staleness would
# pollute every case's report.
_sls_controlled_path="/usr/bin:/bin:/usr/sbin:/sbin"

_sls_tmp="$(mktemp -d)"
trap 'rm -rf "$_sls_tmp"' EXIT
_sls_home="$_sls_tmp/home"
mkdir -p "$_sls_home"

# Substitute every build-time token the way src/modules/shell/default.nix
# does, with benign values: a no-op statement for the injected check lines,
# never-present paths for the devin probe and the default tools root. Tokens
# reach the test source un-substituted otherwise, and a bare token line would
# abort sourcing before the scrubber ever runs.
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
# would die with "command not found: compinit" before reaching the scrubber.
# After sourcing it prints the state of the variables under test so the cases
# assert observed repair, not just the report.
_sls_driver="$_sls_tmp/driver.zsh"
cat >"$_sls_driver" <<EOF
autoload -Uz compinit
. "$_sls_init"
print -- "NIX_CC=\${NIX_CC-<unset>}"
print -- "SDKROOT=\${SDKROOT-<unset>}"
print -- "PATH=\${PATH-<unset>}"
EOF

# run_init_case ERRFILE OUTFILE [VAR=VALUE ...]: source the substituted init
# under zsh -f from inside the temp dir (keeping the prek hook away from a
# real repo) with an empty inherited environment: the test process may itself
# sit inside a stale devShell (dead builder, stdenv, NIX_* vars), and ambient
# staleness would pollute every case's report. HOME points at the temp dir so
# compinit writes nothing real; case assignments come last so they win.
run_init_case() { # <err-file> <out-file> [VAR=VALUE ...]
  local _err="$1"
  local _out="$2"
  shift 2
  (
    cd "$_sls_tmp" || exit 1
    env -i PATH="$_sls_controlled_path" HOME="$_sls_home" \
      "$@" zsh -f "$_sls_driver" </dev/null >"$_out" 2>"$_err"
  )
}

assert_dropped() { # <label> <err-file>
  if grep -qF "$_sls_prefix" "$2"; then
    assert_pass "$1"
  else
    assert_fail "$1" "drop report missing; stderr: $(tr '\n' ' ' <"$2")"
  fi
}

assert_no_report() { # <label> <err-file>
  if grep -qF "$_sls_prefix" "$2"; then
    assert_fail "$1" "unexpected drop report; stderr: $(tr '\n' ' ' <"$2")"
  else
    assert_pass "$1"
  fi
}

assert_no_remedy() { # <label> <err-file>
  if grep -qF "$_sls_remedy" "$2"; then
    assert_fail "$1" "unexpected devShell remedy; stderr: $(tr '\n' ' ' <"$2")"
  else
    assert_pass "$1"
  fi
}

_err="$_sls_tmp/err.txt"
_out="$_sls_tmp/out.txt"

# A dead NIX_CC is the failing-cargo case: report it, point at the devShell
# remedy, and observe the variable actually gone.
run_init_case "$_err" "$_out" "NIX_CC=$_sls_dead"
assert_dropped "dead NIX_CC is reported" "$_err"
if grep -qF "NIX_CC=$_sls_dead" "$_err"; then
  assert_pass "dead NIX_CC report names the dead value"
else
  assert_fail "dead NIX_CC report names the dead value" \
    "stderr: $(tr '\n' ' ' <"$_err")"
fi
if grep -qF "$_sls_remedy" "$_err"; then
  assert_pass "dead NIX_CC prints the devShell remedy"
else
  assert_fail "dead NIX_CC prints the devShell remedy" \
    "stderr: $(tr '\n' ' ' <"$_err")"
fi
if grep -qx 'NIX_CC=<unset>' "$_out"; then
  assert_pass "dead NIX_CC is unset after sourcing"
else
  assert_fail "dead NIX_CC is unset after sourcing" \
    "stdout: $(tr '\n' ' ' <"$_out")"
fi

# A dead entry inside PATH: drop it, keep the live entries in order, collapse
# a repeated live entry, and skip the devShell remedy (no NIX_ var dropped).
_sls_live_path="/usr/bin:/bin:/usr/sbin"
run_init_case "$_err" "$_out" \
  "PATH=$_sls_live_path:$_sls_dead/bin:$_sls_live_path"
assert_dropped "dead PATH entry is reported" "$_err"
assert_no_remedy "dead PATH entry alone prints no devShell remedy" "$_err"
if grep -qx "PATH=$_sls_live_path" "$_out"; then
  assert_pass "dead PATH entry dropped, live entries kept in order, duplicates collapsed"
else
  assert_fail "dead PATH entry dropped, live entries kept in order, duplicates collapsed" \
    "stdout: $(tr '\n' ' ' <"$_out")"
fi

# A dead SDKROOT, spelled as a subpath of a dead store entry: the store entry
# itself is gone, so report and unset. SDKROOT carries no NIX_ prefix, so the
# devShell remedy must stay silent.
run_init_case "$_err" "$_out" "SDKROOT=$_sls_dead_sub"
assert_dropped "dead SDKROOT is reported" "$_err"
assert_no_remedy "dead SDKROOT prints no devShell remedy" "$_err"
if grep -qx 'SDKROOT=<unset>' "$_out"; then
  assert_pass "dead SDKROOT is unset after sourcing"
else
  assert_fail "dead SDKROOT is unset after sourcing" \
    "stdout: $(tr '\n' ' ' <"$_out")"
fi

# A store-prefixed value that is not hash-shaped: untouched and silent.
# Proves the scrubber checks the store-hash shape and existence, not the
# prefix alone.
run_init_case "$_err" "$_out" "NIX_CC=$_sls_live"
assert_no_report "live, non-hash-shaped store prefix: no report" "$_err"
if grep -qx "NIX_CC=$_sls_live" "$_out"; then
  assert_pass "live, non-hash-shaped store prefix is untouched"
else
  assert_fail "live, non-hash-shaped store prefix is untouched" \
    "stdout: $(tr '\n' ' ' <"$_out")"
fi

# No inherited stale values: complete silence on stderr.
run_init_case "$_err" "$_out"
if [ -s "$_err" ]; then
  assert_fail "clean environment: no stderr output" \
    "stderr: $(tr '\n' ' ' <"$_err")"
else
  assert_pass "clean environment: no stderr output"
fi

# The scrubber must survive re-sourcing without repeating itself.
_sls_twice="$_sls_tmp/twice.zsh"
cat >"$_sls_twice" <<EOF
autoload -Uz compinit
. "$_sls_init"
. "$_sls_init"
EOF
(
  cd "$_sls_tmp" || exit 1
  env -i PATH="$_sls_controlled_path" HOME="$_sls_home" \
    "NIX_CC=$_sls_dead" \
    zsh -f "$_sls_twice" </dev/null >/dev/null 2>"$_err"
)
_report_count="$(grep -cF "$_sls_prefix" "$_err" || true)"
if [ "$_report_count" -eq 1 ]; then
  assert_pass "re-sourcing the init reports exactly once"
else
  assert_fail "re-sourcing the init reports exactly once" \
    "reported $_report_count times"
fi

finish_tests
