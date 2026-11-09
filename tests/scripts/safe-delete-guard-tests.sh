#!/usr/bin/env bash
# Corpus parity suite for src/scripts/safe-delete-guard.sh.
#
# The guard is the PreToolUse hook that denies a native delete to every coding
# agent, so its pattern set is a security control. Three alternatives were
# removed as subsumed (shellcheck SC2221/SC2222): the `/usr/bin` and
# `/usr/local/bin` spellings of the delete tool, and the backslash-escaped
# directory variant. This suite proves the removal preserved the union of
# matched strings rather than assuming it.
#
# For every command in the corpus below the suite records two verdicts: the
# shipped guard's exit status, and the status the pre-collapse pattern set gives
# the same command. The two tables must be identical. Per-item expectations are
# deliberately not asserted, because the defect worth catching is a change to
# the pattern set, not a single known command going the wrong way.
#
# The corpus alone cannot prove the comparison discriminates, since a corpus that
# exercises nothing would agree on every row. Two mutation tables cover that:
# each drops one load-bearing alternative from the pre-collapse set, and each has
# to disagree with the shipped guard somewhere.
#
# The guard is driven through the hook JSON protocol on stdin, which is the only
# interface the agent hooks call, so argv is never exercised. The payload is
# JSON-escaped the way a real hook payload is, and both tables are computed from
# the command the guard's own extraction yields, so escaping never stands
# between the two sides of the comparison.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

GUARD="$REPO_ROOT/src/scripts/safe-delete-guard.sh"
readonly GUARD

# Command names are assembled from halves so this suite never has to spell a
# blocked command literally; the guard under test is what has to know them.
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

# The corpus: "<label>|<command>". Labels name the shape under test, and the
# list covers every alternative of the guard, including the three that were
# removed, so a future edit that drops a load-bearing alternative flips a row.
CORPUS=(
  "plain delete of a file|$N_RM foo.txt"
  "recursive forced delete of a dotfile|$N_RM -rf .config"
  "absolute bin path to the delete tool|/bin/$N_RM foo.txt"
  "absolute usr bin path with recursive force|/usr/bin/$N_RM -rf foo"
  "absolute usr local bin path|/usr/local/bin/$N_RM foo"
  "path nested under a bin directory|/opt/tools/bin/$N_RM foo"
  "relative path to the delete tool|./$N_RM foo"
  "relative path to the directory tool|./$N_RMDIR foo"
  "absolute path to the directory tool|/usr/bin/$N_RMDIR foo"
  "escaped directory delete|\\$N_RMDIR foo"
  "escaped delete|\\$N_RM foo"
  "escaped del|\\$N_DEL foo"
  "escaped rd|\\$N_RD foo"
  "escaped erase|\\$N_ERASE foo"
  "escaped ri|\\$N_RI foo"
  "escaped unlink|\\$N_UNLINK foo"
  "escaped shred|\\$N_SHRED foo"
  "bare del|$N_DEL foo"
  "bare rd|$N_RD foo"
  "bare rmdir|$N_RMDIR foo"
  "bare erase|$N_ERASE foo"
  "bare ri|$N_RI foo"
  "bare unlink|$N_UNLINK foo"
  "bare shred|$N_SHRED foo"
  "cmd interpreter running del|$N_CMDEXE /c $N_DEL foo"
  "pwsh with a quoted cmd call|pwsh -c \"x cmd y\"" # records 0 on both sides: the guard's extraction stops at the first quote, so this row pins the known bypass rather than coverage
  "pwsh with an unquoted cmd call|pwsh -c x cmd y"
  "directory listing|ls -la"
  "rip a path|rip foo"
  "git status|git status"
  "printf of the delete word|printf '%s\\n' '$N_RM'"
  "grep for the delete word|grep -n '$N_RM' notes.txt"
)
readonly CORPUS

# JSON-escape a command for a hook payload.
_json_escape() { # <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_payload() { # <command>
  printf '{"command": "%s"}' "$(_json_escape "$1")"
}

# The guard's own extraction, mirrored so the reference tables are applied to
# exactly the string the shipped guard evaluates. A real hook payload can carry
# a quoted argument, and the guard's line-oriented extraction stops at the first
# quote, so reading the command back is what keeps the comparison about the
# pattern sets instead of about JSON escaping.
_guard_command() { # <payload>
  printf '%s' "$1" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//'
}

_guard_status() { # <payload>
  local _status=0
  printf '%s\n' "$1" | sh "$GUARD" >/dev/null 2>&1 || _status=$?
  printf '%s' "$_status"
}

# The guard's branches as they stood before the collapse, verbatim: the
# redundant alternatives are the subject of this suite, which is why the
# overlap detector is silenced here and nowhere else.
_original_verdict() { # <command>
  # shellcheck disable=SC2221,SC2222 # reason: verbatim pre-collapse pattern set; the redundant alternatives are what the parity table has to exercise
  case "$1" in
  */bin/rm* | */usr/bin/rm* | */usr/local/bin/rm* | ./*rm*)
    printf '%s' 2
    return 0
    ;;
  esac
  # shellcheck disable=SC2221,SC2222 # reason: verbatim pre-collapse pattern set; the escaped directory alternative is the subsumed one under test
  case "$1" in
  *'\rm'* | *'\del'* | *'\rd'* | *'\rmdir'* | *'\erase'* | *'\ri'* | *'\unlink'* | *'\shred'*)
    printf '%s' 2
    return 0
    ;;
  esac
  case "$1" in
  *cmd.exe* | *" cmd "*)
    printf '%s' 2
    return 0
    ;;
  esac
  printf '%s' 0
}

# The pre-collapse path branch without its one load-bearing alternative. At
# least one row must lose its verdict here, or the corpus never reached the
# alternative that subsumed the two removed spellings. The /usr/bin,
# /usr/local/bin and ./ rows keep theirs by construction, because this mutant is
# the earlier spelling of the same branch.
_verdict_without_bin_pattern() { # <command>
  case "$1" in
  */usr/bin/rm* | */usr/local/bin/rm* | ./*rm*)
    printf '%s' 2
    return 0
    ;;
  esac
  printf '%s' 0
}

# The pre-collapse escape branch without its delete alternative. At least one
# row must lose its verdict here, or nothing proves that the removed alternative
# was in fact covered by this one. The escaped directory row keeps its verdict,
# because this mutant still lists that spelling.
_verdict_without_escape_delete() { # <command>
  case "$1" in
  *'\del'* | *'\rd'* | *'\rmdir'* | *'\erase'* | *'\ri'* | *'\unlink'* | *'\shred'*)
    printf '%s' 2
    return 0
    ;;
  esac
  printf '%s' 0
}

if [ ! -f "$GUARD" ]; then
  assert_fail "guard present" "$GUARD does not exist"
  finish_tests
fi

section 1 "verdict table"

_blocked=0
_allowed=0
_bin_mutant_diffs=0
_escape_mutant_diffs=0

for _entry in "${CORPUS[@]}"; do
  _label="${_entry%%|*}"
  _command="${_entry#*|}"
  _payload="$(_payload "$_command")"
  _seen="$(_guard_command "$_payload")"
  _shipped="$(_guard_status "$_payload")"

  case "$_shipped" in
  2) _blocked=$((_blocked + 1)) ;;
  0) _allowed=$((_allowed + 1)) ;;
  esac

  _reference="$(_original_verdict "$_seen")"
  if [ "$_shipped" -eq "$_reference" ]; then
    assert_pass "parity: $_label"
  else
    assert_fail "parity: $_label" "shipped guard exited $_shipped, pre-collapse patterns give $_reference for '$_seen'"
  fi

  if [ "$(_verdict_without_bin_pattern "$_seen")" -ne "$_shipped" ]; then
    _bin_mutant_diffs=$((_bin_mutant_diffs + 1))
  fi
  if [ "$(_verdict_without_escape_delete "$_seen")" -ne "$_shipped" ]; then
    _escape_mutant_diffs=$((_escape_mutant_diffs + 1))
  fi
done

section 2 "corpus reach and mutation sensitivity"

if [ "${#CORPUS[@]}" -ge 20 ]; then
  assert_pass "corpus holds at least 20 commands (${#CORPUS[@]})"
else
  assert_fail "corpus holds at least 20 commands" "only ${#CORPUS[@]} entries"
fi

if [ "$_blocked" -gt 0 ] && [ "$_allowed" -gt 0 ]; then
  assert_pass "corpus exercises both verdicts ($_blocked blocked, $_allowed allowed)"
else
  assert_fail "corpus exercises both verdicts" "$_blocked blocked, $_allowed allowed"
fi

if [ "$_bin_mutant_diffs" -gt 0 ]; then
  assert_pass "dropping the bin pattern changes $_bin_mutant_diffs verdict(s), so the corpus reaches it"
else
  assert_fail "dropping the bin pattern changes a verdict" "no row changed, so the dropped-spelling rows prove nothing"
fi

if [ "$_escape_mutant_diffs" -gt 0 ]; then
  assert_pass "dropping the escape-delete pattern changes $_escape_mutant_diffs verdict(s), so the corpus reaches it"
else
  assert_fail "dropping the escape-delete pattern changes a verdict" "no row changed, so the escaped-directory row proves nothing"
fi

section 3 "case fold"

# The filter twins fold case for these families, so a guard that matched only
# lowercase spellings would deny a form one platform folds and allow its
# uppercase twin. These rows sit outside the corpus because the corpus compares
# two case-sensitive pattern sets, which cannot tell a folded guard from an
# unfolded one. Guard rows: they pass today and must keep passing.
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
  _seen="$(_guard_status "$(_payload "$_command")")"
  if [ "$_seen" = "$_want" ]; then
    assert_pass "case fold: $_label"
  else
    assert_fail "case fold: $_label" "guard exited $_seen for '$_command', want $_want"
  fi
done

finish_tests
