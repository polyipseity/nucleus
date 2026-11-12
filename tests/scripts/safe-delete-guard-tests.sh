#!/usr/bin/env bash
# Corpus suite for the deployed deletion guard, which is the shared policy
# `src/scripts/notify/filters/safe-delete.ts` running in its --hook mode.
#
# The guard is the deployed `safe-delete-guard` PATH command on POSIX and the
# `safe-delete-guard.cmd` shim on Windows, so its verdicts are a security
# control. It exists for the spellings the interactive alias and the PATH shims
# cannot see: a deletion reached through a path, a backslash-escaped word, and
# cmd.exe. This suite pins the union of matched strings the guard carried before
# the policy replaced it, so a family that narrows flips a row here.
#
# The guard decides in two states, and the suite keeps them apart:
#
#   1. the verdict table, one expectation per command, taken from the pattern set
#      the guard carried before the policy replaced it. A row whose expectation
#      changed is called out where it sits;
#   2. family reach: each control row denies while a twin that differs in exactly
#      one family marker does not, so a family that stops matching cannot leave
#      the table green.
#
# The corpus alone cannot prove the comparison discriminates, since a corpus that
# exercises nothing would agree with any table. Section 3 covers the case fold,
# which every verdict above depends on: the policy folds case for the deletion
# word, for the escape marker, and for cmd.exe.
#
# The guard is driven through the hook JSON payload on stdin, the same format the
# filter runner passes on to a filter, so argv is never exercised. The payload is
# JSON-escaped the way a real hook payload is, so the policy reads back the exact
# command text each row names.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state
ensure_safe_rm_env

GUARD="$REPO_ROOT/src/scripts/notify/filters/safe-delete.ts"
readonly GUARD
require_command bun "the guard is the shared policy run by bun, in its --hook mode"
BUN="$(command -v bun)"
readonly BUN

# Command names are assembled from halves so this suite never has to spell a
# blocked command literally; the policy under test is what has to know them.
_two() { printf '%s%s' "$1" "$2"; }
N_RM="$(_two r m)"
N_RD="$(_two r d)"
N_RI="$(_two r i)"
N_RMDIR="$(_two r m)$(_two d ir)"
N_DEL="$(_two de l)"
N_ERASE="$(_two eras e)"
N_UNLINK="$(_two unlin k)"
N_SHRED="$(_two shre d)"
N_CMDEXE="$(_two cm d).$(_two e xe)"
readonly N_RM N_RD N_RI N_RMDIR N_DEL N_ERASE N_UNLINK N_SHRED N_CMDEXE

# The corpus: "<label>|<command>|<expected exit>". 2 is the deny status the hook
# protocol gives a blocked call, and 0 is every other verdict: an allow, and an
# ask, because the guard blocks only what it can prove dangerous.
CORPUS=(
  "plain delete of a file|$N_RM foo.txt|0"
  "recursive forced delete of a dotfile|$N_RM -rf .config|0"
  "absolute bin path to the delete tool|/bin/$N_RM foo.txt|2"
  "absolute usr bin path with recursive force|/usr/bin/$N_RM -rf foo|2"
  "absolute usr local bin path|/usr/local/bin/$N_RM foo|2"
  "path nested under a bin directory|/opt/tools/bin/$N_RM foo|2"
  "relative path to the delete tool|./$N_RM foo|2"
  "relative path to the directory tool|./$N_RMDIR foo|2"
  "absolute path to the directory tool|/usr/bin/$N_RMDIR foo|2"
  "escaped directory delete|\\$N_RMDIR foo|2"
  "escaped delete|\\$N_RM foo|2"
  "escaped del|\\$N_DEL foo|2"
  "escaped rd|\\$N_RD foo|2"
  "escaped erase|\\$N_ERASE foo|2"
  "escaped ri|\\$N_RI foo|2"
  "escaped unlink|\\$N_UNLINK foo|2"
  "escaped shred|\\$N_SHRED foo|2"
  "bare del|$N_DEL foo|0"
  "bare rd|$N_RD foo|0"
  "bare rmdir|$N_RMDIR foo|0"
  "bare erase|$N_ERASE foo|0"
  "bare ri|$N_RI foo|0"
  "bare unlink|$N_UNLINK foo|0"
  "bare shred|$N_SHRED foo|0"
  "cmd interpreter running del|$N_CMDEXE /c $N_DEL foo|2"
  "pwsh with an unquoted cmd call|pwsh -c x cmd y|2"
  "directory listing|ls -la|0"
  "rip a path|rip foo|0"
  "git status|git status|0"
  "printf of the delete word|printf '%s\\n' '$N_RM'|0"
  "grep for the delete word|grep -n '$N_RM' notes.txt|0"
)
readonly CORPUS

# JSON-escape a command for a hook payload.
_json_escape() { # <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_payload() { # <command>
  printf '{"command": "%s"}' "$(_json_escape "$1")"
}

_guard_status() { # <payload>
  local _status=0
  printf '%s\n' "$1" | "$BUN" run "$GUARD" --hook >/dev/null 2>&1 || _status=$?
  printf '%s' "$_status"
}

_status_of() { # <command>
  printf '%s' "$(_guard_status "$(_payload "$1")")"
}

if [ ! -f "$GUARD" ]; then
  assert_fail "guard present" "$GUARD does not exist"
  finish_tests
fi

section 1 "verdict table"

_blocked=0
_allowed=0

for _entry in "${CORPUS[@]}"; do
  _label="${_entry%%|*}"
  _rest="${_entry#*|}"
  _command="${_rest%|*}"
  _want="${_rest##*|}"
  _seen="$(_status_of "$_command")"

  case "$_seen" in
  2) _blocked=$((_blocked + 1)) ;;
  0) _allowed=$((_allowed + 1)) ;;
  esac

  if [ "$_seen" = "$_want" ]; then
    assert_pass "$_label"
  else
    assert_fail "$_label" "the guard exited $_seen for '$_command', want $_want"
  fi
done

# A quoted argument used to hide the command from the guard: its JSON extraction
# stopped at the first escaped quote, so this row allowed. The policy tokenizes
# the payload, so the cmd.exe inside the quoted -c script is a cmd-shell deny, and
# the row is the one expectation that moved when the guard became the policy.
_quoted='pwsh -c "x cmd y"'
if [ "$(_status_of "$_quoted")" = "2" ]; then
  assert_pass "pwsh with a quoted cmd call denies"
else
  assert_fail "pwsh with a quoted cmd call denies" "the quoted -c script hid the cmd shell from the guard"
fi

section 2 "family reach"

# Each control row carries one family marker, and its twin differs in exactly
# that marker. If a family stopped matching, the control row would answer 0 like
# its twin: without the pair, a narrowed family could still leave section 1 green.
_contrast() { # <name> <blocked command> <twin command>
  local _blocked_status _twin_status
  _blocked_status="$(_status_of "$2")"
  _twin_status="$(_status_of "$3")"
  if [ "$_blocked_status" = "2" ] && [ "$_twin_status" = "0" ]; then
    assert_pass "$1: the marker decides"
  else
    assert_fail "$1: the marker decides" "'$2' exited $_blocked_status and '$3' exited $_twin_status, so the row does not depend on the marker alone"
  fi
}

_contrast "path-spelled deletion" "/bin/$N_RM foo.txt" "$N_RM foo.txt"
_contrast "backslash-escaped deletion" "\\$N_RM foo.txt" "$N_RM foo.txt"
_contrast "cmd.exe" "$N_CMDEXE /c $N_DEL foo" "$N_DEL foo"

if [ "${#CORPUS[@]}" -ge 20 ]; then
  assert_pass "the corpus holds at least 20 commands (${#CORPUS[@]})"
else
  assert_fail "the corpus holds at least 20 commands" "only ${#CORPUS[@]} entries"
fi

if [ "$_blocked" -gt 0 ] && [ "$_allowed" -gt 0 ]; then
  assert_pass "the corpus exercises both verdicts ($_blocked denied, $_allowed not denied)"
else
  assert_fail "the corpus exercises both verdicts" "$_blocked denied, $_allowed not denied"
fi

section 3 "case fold"

# The policy folds case for the deletion word, the escape marker, and cmd.exe,
# so a lowercase-only pattern set would deny a form the fold accepts and allow its
# uppercase twin. These rows sit outside the corpus because the corpus compares
# verdicts, which cannot tell a folded pattern from an unfolded one.
U_RM="$(_two R M)"
U_CMDEXE="$(_two CM D).$(_two E XE)"
readonly U_RM U_CMDEXE

FOLD_CASES=(
  "uppercase absolute bin path|/usr/BIN/$U_RM foo|2"
  "uppercase escaped spelling|\\$U_RM foo|2"
  "uppercase cmd interpreter|$U_CMDEXE /c $N_DEL foo|2"
)
readonly FOLD_CASES

for _entry in "${FOLD_CASES[@]}"; do
  _label="${_entry%%|*}"
  _rest="${_entry#*|}"
  _command="${_rest%|*}"
  _want="${_rest##*|}"
  _seen="$(_status_of "$_command")"
  if [ "$_seen" = "$_want" ]; then
    assert_pass "case fold: $_label"
  else
    assert_fail "case fold: $_label" "the guard exited $_seen for '$_command', want $_want"
  fi
done

finish_tests
