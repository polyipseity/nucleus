#!/usr/bin/env bash
# Suite for the harness decision runner (src/scripts/notify/harness-filter.sh),
# the safe-delete filter, and the filter registry.
#
# Five sections, because the interface has these layers:
#
#   1. the filter protocol, driven the way the runner drives a filter, so the
#      decision and the rule name are asserted exactly rather than through a
#      document that carries only a reason;
#   2. the redirect proof, because the filter treats an unproven redirect as not
#      redirected and that decision rests on what the caller's PATH resolves to;
#   3. the runner end to end, one case per harness in the render table, parsed
#      with jq so a shape a harness cannot read fails here;
#   4. aggregation and failure handling, against a fixture registry and fixture
#      filters, because the shipped registry carries one filter and so cannot
#      show that deny outranks ask outranks allow;
#   5. the shipped registry itself.
#
# The runner resolves its filters beside itself and its registry through
# derive_repo_root, so every case runs from a copy of the real runner, the real
# library, and the real filters inside a fixture repository tree: the bytes under
# test are the shipped ones, and the tree is what makes a synthetic filter,
# filter, or registry reachable at all.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state
ensure_safe_rm_env

# The runner puts a call no filter decides to the approval sources. This suite is
# about aggregation, so the sources are switched off: an empty list answers `ask`
# at once, which is the value every assertion below compares against. The gate
# itself, including its terminal, is covered by harness-approval-sources-tests.sh.
mkdir -p "$HOME/.local/state/nucleus"
printf '%s\n' '{"harness-approval":{"sources":[]}}' >"$HOME/.local/state/nucleus/config.json"

RUNNER="$REPO_ROOT/src/scripts/notify/harness-filter.sh"
APPROVAL="$REPO_ROOT/src/scripts/notify/harness-approval.sh"
FILTER_DIR="$REPO_ROOT/src/scripts/notify/filters"
LIB_DIR="$REPO_ROOT/src/scripts/lib/lib.sh"
LIB_DIR_DIR="$REPO_ROOT/src/scripts/lib"
LOGS_APP="$REPO_ROOT/scripts/logs.sh"
REGISTRY="$REPO_ROOT/src/modules/configs/harness-filters.json"
readonly RUNNER FILTER_DIR LIB_DIR LIB_DIR_DIR LOGS_APP REGISTRY

require_command jq "the runner and the filter registry both need jq"
require_command python3 "the schema file is parsed with python3"

for _required in "$RUNNER" "$APPROVAL" "$FILTER_DIR/safe-delete.sh" "$LIB_DIR" "$LIB_DIR_DIR/harness-audit.sh" "$LOGS_APP" "$REGISTRY"; do
  if [ ! -e "$_required" ]; then
    assert_fail "runner assets present" "$_required does not exist"
    finish_tests
  fi
done

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064 # reason: WORK is readonly and already resolved, so expanding now is the same value and survives the exit path
trap "rm -rf '$WORK'" EXIT

# The log root is a suite-owned temp tree, so a case never writes into the real
# one and never depends on repo-root detection to find it.
NUCLEUS_LOG_DIR="$WORK/logs"
export NUCLEUS_LOG_DIR

# A fixture repository tree that holds the shipped runner, library, and filters
# plus the registry, so a case can replace the registry or add a filter without
# touching the checkout.
make_tree() { # <name>
  local _root="$WORK/$1"
  mkdir -p "$_root/scripts" "$_root/src/scripts/lib" "$_root/src/scripts/notify/filters" "$_root/src/modules/configs"
  cp "$RUNNER" "$_root/src/scripts/notify/harness-filter.sh"
  cp "$APPROVAL" "$_root/src/scripts/notify/harness-approval.sh"
  cp "$LIB_DIR" "$_root/src/scripts/lib/lib.sh"
  cp "$LIB_DIR_DIR/harness-audit.sh" "$LIB_DIR_DIR/log-expiry.sh" "$_root/src/scripts/lib/"
  # The bridge entry points source nucleus-logs' writer library from three levels
  # up, so the fixture keeps the same layout the bundle has.
  cp "$LOGS_APP" "$_root/scripts/logs.sh"
  cp "$FILTER_DIR"/*.sh "$_root/src/scripts/notify/filters/"
  cp "$REGISTRY" "$_root/src/modules/configs/harness-filters.json"
  printf '%s\n' "$_root"
}

set_registry() { # <tree> <json>
  printf '%s\n' "$2" >"$1/src/modules/configs/harness-filters.json"
}

# A fixture filter, named the way the registry names it. %b expands the body's
# \n escapes: written literally, a body whose second line starts with a redirect
# leaves ">&2\nexit 3" on one line, where bash reads it as a `>&2nexit` redirect
# in the suite's working directory and no failing exit at all.
add_filter() { # <tree> <id> <body>
  printf '#!/usr/bin/env bash\n%b\n' "$3" >"$1/src/scripts/notify/filters/$2.sh"
  chmod +x "$1/src/scripts/notify/filters/$2.sh"
}

run_runner() { # <tree> <harness> <payload>
  local _root="$1"
  local _harness="$2"
  local _payload="$3"
  NUCLEUS_REPO_ROOT="$_root" "$_root/src/scripts/notify/harness-filter.sh" "$_harness" <<<"$_payload"
}

run_filter() { # <settings> <command>
  "$FILTER_DIR/safe-delete.sh" --settings "$1" --command "$2" </dev/null
}

# The redirect proof depends on the caller's PATH and HOME, so those cases set
# both and run the filter through this shell's own bash. The interpreter is named
# outright because a case that narrows PATH to the point of carrying no deletion
# command would otherwise lose the shebang's `env bash` lookup too.
run_filter_env() { # <home> <path> <settings> <command>
  HOME="$1" PATH="$2" "$BASH_PATH" "$FILTER_DIR/safe-delete.sh" --settings "$3" --command "$4" </dev/null
}

assert_decision() { # <name> <line> <decision> <rule>
  local _seen_decision _seen_rule
  _seen_decision="$(printf '%s' "$2" | cut -f1)"
  _seen_rule="$(printf '%s' "$2" | cut -f2)"
  if [ "$_seen_decision" = "$3" ] && [ "$_seen_rule" = "$4" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "got '$2', want decision '$3' rule '$4'"
  fi
}

# assert_document <name> <json> <jq expression>
assert_document() {
  local _name="$1"
  local _json="$2"
  local _expression="$3"
  if ! jq -e "$_expression" >/dev/null 2>&1 <<<"$_json"; then
    assert_fail "$_name" "document '$_json' does not satisfy $_expression"
    return 0
  fi
  assert_pass "$_name"
}

section 1 "filter protocol (safe-delete)"

# "<settings>|<command>|<decision>|<rule>"
FILTER_CASES=(
  '{"unproven":"deny"}|/bin/rm -rf x|deny|native-path'
  '{"unproven":"deny"}|/usr/local/bin/rm x|deny|native-path'
  '{"unproven":"deny"}|./rm x|deny|native-path'
  '{"unproven":"deny"}|\rm x|deny|escaped-spelling'
  '{"unproven":"deny"}|\unlink x|deny|escaped-spelling'
  '{"unproven":"deny"}|cmd.exe /c del x|deny|cmd-shell'
  '{"unproven":"deny"}|pwsh -c x cmd y|deny|cmd-shell'
  '{"unproven":"deny"}|rm x|deny|unproven-redirect'
  '{"unproven":"deny"}|rm -rf build|deny|unproven-redirect'
  '{"unproven":"route"}|rm x|ask|unproven-redirect'
  '{}|rm x|deny|unproven-redirect'
  '{"unproven":"allow"}|rm x|allow|unproven-redirect'
  '{"unproven":"deny"}|ls -la|allow|no-match'
  '{"unproven":"deny"}|git status|allow|no-match'
)
readonly FILTER_CASES

for _case in "${FILTER_CASES[@]}"; do
  IFS='|' read -r _settings _command _decision _rule <<<"$_case"
  assert_decision "$_rule: $_command" "$(run_filter "$_settings" "$_command")" "$_decision" "$_rule"
done

section 2 "redirect proof (safe-delete)"

# The managed wrapper the proof looks for is ~/.local/bin/<verb>, and the filter
# treats anything else as not redirected. These fixtures are the four shapes that
# answer: the deployed symlink, a plain file at the same path, an absent command,
# and a plain rm ahead of everything on PATH.
BASH_PATH="$(command -v bash)"
PROVEN_HOME="$WORK/proven-home"
PLAIN_WRAPPER_HOME="$WORK/plain-wrapper-home"
EMPTY_HOME="$WORK/empty-home"
PLAIN_BIN="$WORK/plain-bin"
MIN_BIN="$WORK/min-bin"
readonly BASH_PATH PROVEN_HOME PLAIN_WRAPPER_HOME EMPTY_HOME PLAIN_BIN MIN_BIN
mkdir -p "$PROVEN_HOME/.local/bin" "$PLAIN_WRAPPER_HOME/.local/bin" "$EMPTY_HOME" "$PLAIN_BIN" "$MIN_BIN"
# WHY a symlink to a real executable: `command -v` skips a target it cannot run,
# so a dangling link would read as a missing command and prove the wrong case.
ln -s /bin/sh "$PROVEN_HOME/.local/bin/rm"
printf '#!/bin/sh\nexit 0\n' >"$PLAIN_WRAPPER_HOME/.local/bin/rm"
printf '#!/bin/sh\nexit 0\n' >"$PLAIN_BIN/rm"
chmod +x "$PLAIN_WRAPPER_HOME/.local/bin/rm" "$PLAIN_BIN/rm"
# The filter needs jq for its settings and sh for the lookup, and nothing else.
for _tool in jq sh; do
  ln -s "$(command -v "$_tool")" "$MIN_BIN/$_tool"
done

PROVEN_PATH="$PROVEN_HOME/.local/bin:$MIN_BIN"
NO_RM_PATH="$MIN_BIN"
PLAIN_PATH="$PLAIN_BIN:$MIN_BIN"
readonly PROVEN_PATH NO_RM_PATH PLAIN_PATH

assert_decision "a proven redirect allows under deny" \
  "$(run_filter_env "$PROVEN_HOME" "$PROVEN_PATH" '{"unproven":"deny"}' 'rm x')" allow proven-redirect
assert_decision "a proven redirect allows under route" \
  "$(run_filter_env "$PROVEN_HOME" "$PROVEN_PATH" '{"unproven":"route"}' 'rm x')" allow proven-redirect
assert_decision "a proven redirect allows under allow" \
  "$(run_filter_env "$PROVEN_HOME" "$PROVEN_PATH" '{"unproven":"allow"}' 'rm x')" allow proven-redirect
assert_decision "a missing rm is unproven and denies by default" \
  "$(run_filter_env "$EMPTY_HOME" "$NO_RM_PATH" '{"unproven":"deny"}' 'rm x')" deny unproven-redirect
assert_decision "an absent settings.unproven denies" \
  "$(run_filter_env "$EMPTY_HOME" "$NO_RM_PATH" '{}' 'rm x')" deny unproven-redirect
assert_decision "an unproven redirect routes when configured" \
  "$(run_filter_env "$EMPTY_HOME" "$NO_RM_PATH" '{"unproven":"route"}' 'rm x')" ask unproven-redirect
assert_decision "an unproven redirect allows when configured" \
  "$(run_filter_env "$EMPTY_HOME" "$NO_RM_PATH" '{"unproven":"allow"}' 'rm x')" allow unproven-redirect
assert_decision "an unknown settings.unproven denies instead of allowing" \
  "$(run_filter_env "$EMPTY_HOME" "$NO_RM_PATH" '{"unproven":"maybe"}' 'rm x')" deny unproven-redirect
assert_decision "a plain rm ahead of the wrapper on PATH is unproven and denies" \
  "$(run_filter_env "$EMPTY_HOME" "$PLAIN_PATH" '{"unproven":"deny"}' 'rm x')" deny unproven-redirect
assert_decision "a plain file at the wrapper path is unproven and denies" \
  "$(run_filter_env "$PLAIN_WRAPPER_HOME" "$PLAIN_WRAPPER_HOME/.local/bin:$MIN_BIN" '{"unproven":"deny"}' 'rm x')" deny unproven-redirect

# The three bypass families are the spellings no redirect can cover, so the
# setting that governs an unproven redirect must not reach them.
for _setting in deny route allow; do
  for _case in '/bin/rm -rf x|deny|native-path' './rm x|deny|native-path' '\rm x|deny|escaped-spelling' 'cmd.exe /c del x|deny|cmd-shell'; do
    IFS='|' read -r _command _decision _rule <<<"$_case"
    assert_decision "$_rule stays denied under unproven=$_setting: $_command" \
      "$(run_filter_env "$PROVEN_HOME" "$PROVEN_PATH" "{\"unproven\":\"$_setting\"}" "$_command")" "$_decision" "$_rule"
  done
done

section 3 "runner render table"

TREE="$(make_tree runner)"

_copilot_deny="$(run_runner "$TREE" copilot '{"tool_name":"runInTerminal","tool_input":{"command":"/bin/rm -rf x"}}')"
assert_document "copilot: native path is denied" "$_copilot_deny" \
  '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("safe-delete (native-path)"))'

_cursor_deny="$(run_runner "$TREE" cursor '{"command":"/bin/rm -rf x"}')"
if [ "$_cursor_deny" = '{"permission":"deny"}' ]; then
  assert_pass "cursor: native path renders the byte-identical permission document"
else
  assert_fail "cursor: native path renders the byte-identical permission document" "got '$_cursor_deny'"
fi
assert_document "cursor: document parses as JSON" "$_cursor_deny" '.permission == "deny"'

_copilot_unproven="$(run_runner "$TREE" copilot '{"command":"rm x"}')"
assert_document "copilot: a plain delete with an unproven redirect is denied" "$_copilot_unproven" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("unproven-redirect"))'

_cursor_unproven="$(run_runner "$TREE" cursor '{"command":"rm x"}')"
assert_document "cursor: a plain delete with an unproven redirect is denied" "$_cursor_unproven" '.permission == "deny"'

_claude_deny="$(run_runner "$TREE" claude '{"command":"/bin/rm -rf x"}')"
assert_document "claude: native path is denied" "$_claude_deny" \
  '.hookSpecificOutput.permissionDecision == "deny"'

if [ "$(run_runner "$TREE" pi '{"command":"/bin/rm x"}')" = "deny" ]; then
  assert_pass "pi: plain deny word"
else
  assert_fail "pi: plain deny word" "the plain-word render is what pi reads from its last stdout line"
fi

if [ "$(run_runner "$TREE" codex '{"command":"/bin/rm x"}')" = "deny" ]; then
  assert_pass "codex: plain deny word"
else
  assert_fail "codex: plain deny word" "codex has no document shape, so the plain word is its render"
fi

if [ "$(run_runner "$TREE" opencode '{"command":"ls -la"}')" = "allow" ]; then
  assert_pass "opencode: an ungated command is allowed"
else
  assert_fail "opencode: an ungated command is allowed" "a command no filter matches must not become a prompt"
fi

if [ "$(run_runner "$TREE" unknown-harness '{"command":"/bin/rm x"}')" = "deny" ]; then
  assert_pass "fallback: an unknown harness gets the plain word"
else
  assert_fail "fallback: an unknown harness gets the plain word" "the fallback render is the plain decision"
fi

# One document per call: a second line would be a second decision for a harness
# that reads either the whole stdout or its last line.
for _doc_harness in claude copilot cursor opencode pi; do
  _count="$(run_runner "$TREE" "$_doc_harness" '{"command":"/bin/rm -rf x"}' | wc -l | tr -d ' ')"
  if [ "$_count" = "1" ]; then
    assert_pass "exactly one document for $_doc_harness"
  else
    assert_fail "exactly one document for $_doc_harness" "the runner printed $_count line(s)"
  fi
done

_no_command="$(run_runner "$TREE" copilot '{"tool_name":"readFile","tool_input":{"path":"x"}}')"
assert_document "a payload without a command asks, never allows by omission" "$_no_command" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("not-a-command"))'

# An undecided call is not an authorisation: a registry that disables every
# filter must prompt, not silently allow.
_undecided_tree="$(make_tree undecided)"
set_registry "$_undecided_tree" '{"filters":[{"enabled":false,"id":"safe-delete","settings":{}}]}'
_undecided="$(run_runner "$_undecided_tree" copilot '{"command":"ls -la"}')"
assert_document "a call no filter decides asks with no-filter" "$_undecided" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("no-filter"))'

# A JSON payload behind leading whitespace is still JSON. The command is a plain
# delete on purpose: behind the prefix the deletion pattern cannot match, so
# without the strip this payload takes the raw-command path and answers allow with
# no rule, while with the strip it parses and the deletion filter denies it with
# unproven-redirect.
_leading="$(run_runner "$TREE" copilot '  {"command":"rm x"}')"
assert_document "a payload with leading whitespace is still parsed as JSON" "$_leading" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("unproven-redirect"))'

NO_REGISTRY_TREE="$(make_tree no-registry)"
rm -f "$NO_REGISTRY_TREE/src/modules/configs/harness-filters.json"
_missing="$(run_runner "$NO_REGISTRY_TREE" copilot '{"command":"ls"}')"
assert_document "a missing registry asks instead of allowing silently" "$_missing" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("registry-error"))'

section 4 "aggregation and filter failure"

AGG="$(make_tree aggregation)"
add_filter "$AGG" allow-first 'printf "allow\tno-match\tfirst\n"'
add_filter "$AGG" ask-second 'printf "ask\tunproven-redirect\tsecond\n"'
add_filter "$AGG" deny-third 'printf "deny\tnative-path\tthird\n"'
add_filter "$AGG" crash "printf 'boom\n' >&2\nexit 3"
add_filter "$AGG" garbage 'printf "not a decision line\n"'

set_registry "$AGG" '{"filters":[{"enabled":true,"id":"allow-first","settings":{}},{"enabled":true,"id":"ask-second","settings":{}},{"enabled":true,"id":"deny-third","settings":{}}]}'
if [ "$(run_runner "$AGG" copilot '{"command":"anything"}')" = "$(printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"deny-third (native-path): third"}}')" ]; then
  assert_pass "deny outranks ask and allow"
else
  assert_fail "deny outranks ask and allow" "the aggregate was not the deny entry last in registry order"
fi

set_registry "$AGG" '{"filters":[{"enabled":true,"id":"deny-third","settings":{}},{"enabled":true,"id":"ask-second","settings":{}},{"enabled":true,"id":"allow-first","settings":{}}]}'
_agg_reversed="$(run_runner "$AGG" copilot '{"command":"anything"}')"
# The earlier deny wins the tie, so the reason names the filter that ran first:
# aggregation must not depend on registry order.
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$_agg_reversed")" = "deny" ]; then
  assert_pass "deny outranks the rest from any registry position"
else
  assert_fail "deny outranks the rest from any registry position" "got '$_agg_reversed'"
fi

set_registry "$AGG" '{"filters":[{"enabled":true,"id":"allow-first","settings":{}},{"enabled":true,"id":"ask-second","settings":{}}]}'
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$(run_runner "$AGG" copilot '{"command":"anything"}')")" = "ask" ]; then
  assert_pass "ask outranks allow"
else
  assert_fail "ask outranks allow" "an ask beside an allow has to prompt"
fi

set_registry "$AGG" '{"filters":[{"enabled":false,"id":"deny-third","settings":{}},{"enabled":true,"id":"allow-first","settings":{}}]}'
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$(run_runner "$AGG" copilot '{"command":"anything"}')")" = "allow" ]; then
  assert_pass "a disabled entry does not run"
else
  assert_fail "a disabled entry does not run" "the disabled deny still decided"
fi

set_registry "$AGG" '{"filters":[{"enabled":true,"id":"crash","settings":{}}]}'
_crash="$(run_runner "$AGG" copilot '{"command":"anything"}')"
# The reason distinguishes a filter that exited non-zero from one that printed
# nothing: both carry rule filter-error, so only the text proves the exit status
# was what produced the verdict.
assert_document "a crashing filter is recorded as filter-error" "$_crash" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("filter-error")) and (.hookSpecificOutput.permissionDecisionReason | contains("exited non-zero"))'

set_registry "$AGG" '{"filters":[{"enabled":true,"id":"garbage","settings":{}}]}'
_garbage="$(run_runner "$AGG" copilot '{"command":"anything"}')"
assert_document "a filter printing no protocol line is recorded as filter-error" "$_garbage" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("filter-error")) and (.hookSpecificOutput.permissionDecisionReason | contains("no decision line"))'

set_registry "$AGG" '{"filters":[{"enabled":true,"id":"absent","settings":{}}]}'
_absent="$(run_runner "$AGG" copilot '{"command":"anything"}')"
assert_document "a registry entry with no filter script is recorded as filter-error" "$_absent" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | contains("filter-error"))'

section 5 "shipped registry"

if jq -e '.filters | length >= 1' "$REGISTRY" >/dev/null 2>&1; then
  assert_pass "the registry declares at least one filter"
else
  assert_fail "the registry declares at least one filter" "$REGISTRY has an empty filters array"
fi

if jq -e '.filters[] | select(.id == "safe-delete" and .enabled == true and .settings.unproven == "deny")' "$REGISTRY" >/dev/null 2>&1; then
  assert_pass "safe-delete is enabled with settings.unproven at its deny default"
else
  assert_fail "safe-delete is enabled with settings.unproven at its deny default" "$REGISTRY does not enable it with the documented default"
fi

if jq -e '.["$schema"] == "./harness-filters.schema.json"' "$REGISTRY" >/dev/null 2>&1; then
  assert_pass "the registry carries its inline schema pointer"
else
  assert_fail "the registry carries its inline schema pointer" "$REGISTRY has no co-located \$schema"
fi

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$REPO_ROOT/src/modules/configs/harness-filters.schema.json"; then
  assert_pass "the schema file parses as JSON"
else
  assert_fail "the schema file parses as JSON" "harness-filters.schema.json is not valid JSON"
fi

finish_tests
