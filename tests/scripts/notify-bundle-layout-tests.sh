#!/usr/bin/env bash
# Test: the notify scripts reach their log library from a store app.
#
# The store app links $out/src to script-tree/src, so a source path that climbs
# out of the tree lands where the bundled tree has no scripts/. The home is a
# fixture too: the redirect proof compares PATH's rm against
# $HOME/.local/bin/rm, so the suite cannot lean on a provisioned host.

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT

require_command bun "the runner starts every filter as a bun program"
require_command jq "the audit event is asserted as JSON"

ensure_safe_rm_env

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# Builds the store layout: the script tree carries src/scripts/ only, the app
# reaches it through a src symlink, and nothing sits beside the tree. The home
# carries a managed rm wrapper and PATH puts it first, so the filter proves the
# redirect from the fixture.
make_store_layout() { # <dir>
  local _tmp="$1"
  mkdir -p "$_tmp/tree" "$_tmp/app" "$_tmp/logs" \
    "$_tmp/home/.local/bin" "$_tmp/hm/home-manager-files/.local/bin"
  cp -R "$REPO_ROOT/src/scripts" "$_tmp/tree/scripts"
  ln -s "$_tmp/tree" "$_tmp/app/src"
  # WHY a plain file: the wrapper is only stat'ed, realpath'ed, and readlink'ed,
  # never run, and the home-manager marker in its path is what proves it.
  : >"$_tmp/hm/home-manager-files/.local/bin/rm"
  chmod 755 "$_tmp/hm/home-manager-files/.local/bin/rm"
  ln -s "$_tmp/hm/home-manager-files/.local/bin/rm" "$_tmp/home/.local/bin/rm"
}

section 1 "store layout"

LAYOUT="$WORK/layout"
make_store_layout "$LAYOUT"
RUNNER="$LAYOUT/app/src/scripts/notify/harness-filter.sh"
AUDIT="$LAYOUT/logs/harness.log"

_rc=0
_stdout="$(printf '%s' '{"tool_name":"bash","tool_input":{"command":"rm -f /tmp/store-layout-probe"}}' |
  env HOME="$LAYOUT/home" PATH="$LAYOUT/home/.local/bin:$PATH" \
    NUCLEUS_REPO_ROOT="$REPO_ROOT" NUCLEUS_LOG_DIR="$LAYOUT/logs" NO_COLOR=1 \
    bash "$RUNNER" pi 2>"$WORK/stderr")" || _rc=$?
_stderr="$(cat "$WORK/stderr")"

if [ "$_rc" -eq 0 ] && [ "$_stdout" = "allow" ]; then
  assert_pass "the store layout prints the filter verdict"
else
  assert_fail "store layout verdict" "rc=$_rc stdout='$_stdout' stderr: $_stderr"
fi

case "$_stderr" in
*"could not write"* | *"No such file"*)
  assert_fail "the store layout reaches its log library" "$_stderr"
  ;;
*)
  assert_pass "the store layout reaches its log library"
  ;;
esac

_lines=0
if [ -f "$AUDIT" ]; then
  _lines="$(wc -l <"$AUDIT" | tr -d ' ')"
fi
if [ "$_lines" = 1 ] &&
  jq -e '.source == "filter" and .decision == "allow" and .rule == "proven-redirect"' "$AUDIT" >/dev/null 2>&1; then
  assert_pass "the store layout appends one audit event"
else
  assert_fail "store layout audit event" "lines=$_lines event: $(cat "$AUDIT" 2>/dev/null)"
fi

finish_tests
