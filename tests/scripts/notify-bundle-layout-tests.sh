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
RUNNER="$LAYOUT/app/src/scripts/notify/harness/decide-call.sh"
AUDIT="$LAYOUT/logs/harness.log"

_rc=0
_stdout="$(printf '%s' '{"tool_name":"bash","tool_input":{"command":"rm -f /tmp/store-layout-probe"}}' |
  env HOME="$LAYOUT/home" PATH="$LAYOUT/home/.local/bin:$PATH" \
    NUCLEUS_REPO_ROOT="$REPO_ROOT" NUCLEUS_LOG_DIR="$LAYOUT/logs" NO_COLOR=1 \
    bash "$RUNNER" pi 2>"$WORK/stderr")" || _rc=$?
_stderr="$(cat "$WORK/stderr")"

# The filter's reason embeds the fixture wrapper path, so build the exact
# expected document from the layout rather than checking a fragment of it.
_expected_reason="safe-delete (proven-redirect): deletion command: rm resolves to the home-manager safe-delete wrapper at $LAYOUT/home/.local/bin/rm"
if [ "$_rc" -eq 0 ] && jq -eM --arg reason "$_expected_reason" \
  '.version == 1 and .decision == "allow" and .reason == $reason and
   .source == "none" and .timeouts == {"hermes": 300, "prompt": 600} and
   (.timedOutSources == [])' <<<"$_stdout" >/dev/null; then
  assert_pass "the store layout prints the typed filter verdict"
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

section 2 "notify manifest/deployment surface"

# Task 2 command-surface cleanup: harness bridge implementations stay in
# src/scripts/notify and are dispatched via nucleus-utils, not deployed as
# standalone ~/.local/bin harness executables.
if ! grep -Eq 'home\.file\."\.(local)/bin/harness-' "$REPO_ROOT/src/modules/agents.nix" "$REPO_ROOT/src/modules/shell/default.nix"; then
  assert_pass "agents.nix and shell/default.nix deploy no harness-* ~/.local/bin executables"
else
  assert_fail "agents.nix and shell/default.nix deploy no harness-* ~/.local/bin executables" "found harness-* home.file .local/bin entry"
fi

if ! grep -Eq 'home\.file\."\.(local)/bin/safe-delete-guard"' "$REPO_ROOT/src/modules/shell/default.nix"; then
  assert_pass "shell/default.nix deploys no safe-delete-guard ~/.local/bin executable"
else
  assert_fail "shell/default.nix deploys no safe-delete-guard ~/.local/bin executable" "found safe-delete-guard home.file entry"
fi

# Implementation scripts remain in src/scripts/notify; filter files and shared
# policy stay under filters/. No standalone deployed wrapper files belong here.
for _f in "$REPO_ROOT/src/scripts/notify/harness/send-notification.sh" "$REPO_ROOT/src/scripts/notify/harness/send-notification.ps1" "$REPO_ROOT/src/scripts/notify/harness/request-approval.sh" "$REPO_ROOT/src/scripts/notify/harness/request-approval.ps1" "$REPO_ROOT/src/scripts/notify/harness/decide-call.sh" "$REPO_ROOT/src/scripts/notify/harness/decide-call.ps1" "$REPO_ROOT/src/scripts/notify/harness/continue-turn.sh" "$REPO_ROOT/src/scripts/notify/harness/continue-turn.ps1"; do
  if [ ! -f "$_f" ]; then
    assert_fail "notify harness implementations exist at new bundle paths" "missing $_f"
    finish_tests
  fi
done
if [ -d "$REPO_ROOT/src/scripts/notify/filters" ]; then
  assert_pass "notify harness implementations exist at new bundle paths"
else
  assert_fail "notify implementations and filter directory remain in src/scripts/notify" "expected moved harness scripts and filters/ directory"
fi

finish_tests
