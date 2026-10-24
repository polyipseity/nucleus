#!/usr/bin/env bash
# shellcheck shell=bash
# Test: run_prompt_template_contract rejects each violation class and accepts a compliant tree.
#
# The suite sources the real step file and calls the real function, so deleting a
# rule from the step turns the matching case red. PROMPT_CONTRACT_STEP_FILE points
# the suite at a copy of the step for the drift check.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1

STEP_FILE="${PROMPT_CONTRACT_STEP_FILE:-$REPO_ROOT/src/scripts/checks/check-steps/12-repo-policy-pattern.sh}"

# check-lib.sh sources lib.sh and step-runner.sh, which define the real say,
# error, and register_step. The stubs go in after that and before the step file
# loads, so the step registers nothing and every message lands in a variable.
# shellcheck source=../../../src/scripts/checks/check-lib.sh
. "$REPO_ROOT/src/scripts/checks/check-lib.sh"
register_step() { :; }
_captured=""
error() { _captured+="$*"$'\n'; }
say() { :; }
# shellcheck source=../../../src/scripts/checks/check-steps/12-repo-policy-pattern.sh
. "$STEP_FILE"

failures=0
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT
_raw=""

_fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# Build one fixture tree: a compliant prompt and a balanced policy file.
# Prints the fixture root.
_make_case() {
  local _root="$_tmp/$1"
  mkdir -p "$_root/.agents/prompts" "$_root/.agents/instructions"
  printf '%s\n' 'Read standing-orders.instructions.md first.' "Task: \$@" >"$_root/.agents/prompts/t.prompt.md"
  printf '%s\n' '<!-- child-prompt-block:begin -->' 'block' '<!-- child-prompt-block:end -->' \
    >"$_root/.agents/instructions/standing-orders.instructions.md"
  printf '%s' "$_root"
}

_run_case() {
  _captured=""
  run_prompt_template_contract false "$1" >/dev/null 2>"$_tmp/stderr"
  _rc=$?
  _raw="$(cat "$_tmp/stderr")"
}

_expect_rc() {
  [ "$_rc" -eq "$1" ] || _fail "$2: expected exit $1, got $_rc (stderr: $_raw; messages: $_captured)"
}

_expect_message() {
  case "$_captured" in
  *"$1"*) ;;
  *) _fail "$2: messages do not mention '$1' (got: $_captured)" ;;
  esac
}

_expect_silent_stderr() {
  [ -z "$_raw" ] || _fail "$1: unexpected stderr: $_raw"
}

# 1. A compliant tree passes, and a balanced marker pair is not a violation.
_root=$(_make_case ok)
_run_case "$_root"
_expect_rc 0 "compliant tree"
_expect_silent_stderr "compliant tree"

# 2. A VS Code input variable is rejected.
_root=$(_make_case input)
printf '%s\n' "x \${input:extra}" >>"$_root/.agents/prompts/t.prompt.md"
_run_case "$_root"
_expect_rc 1 "input variable"
_expect_message "cannot expand" "input variable"
_expect_message "$_root/.agents/prompts/t.prompt.md" "input variable names the file"

# 3. A template without a substitution slot is rejected.
_root=$(_make_case slot)
printf '%s\n' 'no slot here' >"$_root/.agents/prompts/t.prompt.md"
_run_case "$_root"
_expect_rc 1 "missing slot"
_expect_message "no argument slot" "missing slot"

# 4. A template without the anchor line is rejected.
_root=$(_make_case anchor)
printf '%s\n' "Task: \$@" >"$_root/.agents/prompts/t.prompt.md"
_run_case "$_root"
_expect_rc 1 "missing anchor"
_expect_message "missing standing-orders anchor line" "missing anchor"

# 5. A harness-specific tool name is rejected.
_root=$(_make_case tool)
printf '%s\n' 'runSubagent(...)' >>"$_root/.agents/prompts/t.prompt.md"
_run_case "$_root"
_expect_rc 1 "harness tool name"
_expect_message "harness-specific name" "harness tool name"

# 6. A /memories/ path is rejected by the same rule.
_root=$(_make_case mem)
printf '%s\n' 'memory view /memories/session/' >>"$_root/.agents/prompts/t.prompt.md"
_run_case "$_root"
_expect_rc 1 "/memories/ path"
_expect_message "harness-specific name" "/memories/ path"

# 7. An unbalanced child-prompt-block marker pair is rejected and names the policy file.
_root=$(_make_case unbalanced)
printf '%s\n' '<!-- child-prompt-block:begin -->' 'block' \
  >"$_root/.agents/instructions/standing-orders.instructions.md"
_run_case "$_root"
_expect_rc 1 "unbalanced markers"
_expect_message "child-prompt-block markers are unbalanced" "unbalanced markers"
_expect_message "$_root/.agents/instructions/standing-orders.instructions.md" "unbalanced markers name the policy file"

# 8. A tree without the policy file passes that rule with no stderr.
_root=$(_make_case nopolicy)
rm -f "$_root/.agents/instructions/standing-orders.instructions.md"
_run_case "$_root"
_expect_rc 0 "missing policy file"
_expect_silent_stderr "missing policy file"

# 9. The real tree satisfies the contract.
_run_case "$REPO_ROOT"
_expect_rc 0 "real repository tree"

if [ "$failures" -ne 0 ]; then
  echo "prompt template contract tests: $failures failed"
  exit 1
fi
echo "prompt template contract tests: passed"
