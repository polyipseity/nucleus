#!/usr/bin/env bash
# WHY: grep-based — `bump-lockfile` was folded into `nucleus-update lockfile`,
# but text naming the removed command survived in two opposite directions. Six
# sites told a reader to run a command that no longer exists, including a JSON
# schema description, which is what an agent reads before editing the
# lockfile. Ten other lines still say "bump-lockfile", and every one of them is
# correct: they describe the deletion, or they are test fixtures.
#
# A mechanical sweep cannot tell those two groups apart — that is why a prior
# pass produced a wrong list. This test encodes the distinction as an explicit
# allowlist and asserts it in BOTH directions: every surviving mention must be
# allowlisted, and every allowlisted line must still exist. A new stale
# reference fails the first; deleting a correct historical note fails the
# second, so the allowlist cannot rot into a blanket suppression.
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOVED="bump-lockfile"

require_command git "the mention scan enumerates tracked files with git grep"

# This file names the removed command in its header, in REMOVED, and in every
# allowlist entry. The scan therefore excludes this path explicitly. Without the
# exclusion the suite is green only while the file is untracked: `git grep` reads
# tracked files, so on commit it classifies each of those lines as an unapproved
# mention and the suite fails. Simulated with `git grep --no-index`.
# Deliberately NOT solved by allowlisting this file's own lines: the suite exists
# to prove the allowlist cannot rot into a blanket suppression, and admitting the
# guard itself would be exactly that.
_SELF="tests/scripts/stale-reference-sites-tests.sh"

# file|line|substring — one entry per line that may legitimately mention the
# removed command. The line number is what makes the entry a *byte* proof rather
# than a substring one: a previous version grepped the whole file for the
# substring, so a reword that preserved the keyword both counted as present and
# whitelisted itself. Pinning the line lets _allowlist_has_not_rotted compare
# that exact line against HEAD, which is the "must-not-touch" promise the brief
# actually asks for. A quoted heredoc: entries carry backticks and a literal
# single quote, and a single-quoted string can only hold those through nested
# quoting that shellcheck reads as an unexpanded expression.
_ALLOWED_LINES=$(
  cat <<'ALLOW_EOF'
scripts/update.ps1|12|bump-lockfile.ps1 (the nucleus command surface merged
scripts/update.ps1|13|bump-lockfile` into
scripts/update.ps1|139|# deleted scripts/bump-lockfile.ps1
scripts/update.sh|173|# scripts/bump-lockfile.sh.
src/scripts/checks/check-steps/10-completions-fresh.ps1|8|in the bump-lockfile completer still has its --list-sections
src/scripts/checks/lockfile-enforcement-lib.ps1|3|bump-lockfile.ps1 -VerifyInstalled.
src/scripts/checks/lockfile-enforcement-lib.ps1|4|safe to source from bump-lockfile.
src/scripts/checks/lockfile-enforcement-lib.ps1|8|and bump-lockfile.ps1 (Write-NucleusInfo
tests/platforms/Windows/modules/Format-NucleusOutput.Tests.ps1|32|nucleus-bump-lockfile.ps1
tests/platforms/Windows/modules/Format-NucleusOutput.Tests.ps1|33|Should -Be 'bump-lockfile'
ALLOW_EOF
)

# True when <file>:<lineno> is a pinned allowlisted line whose text still contains
# the distinguishing substring. Line-scoped, not file-scoped: an entry cannot
# authorise a sibling line in the same file.
_is_allowed() { # <file> <lineno> <line text>
  local _file="$1" _lineno="$2" _line="$3" _entry _ef _en _es
  while IFS= read -r _entry; do
    [ -n "$_entry" ] || continue
    _ef="${_entry%%|*}"
    _en="${_entry#*|}"
    _en="${_en%%|*}"
    _es="${_entry#*|}"
    _es="${_es#*|}"
    if [ "$_ef" = "$_file" ] && [ "$_en" = "$_lineno" ] &&
      { printf '%s' "$_line" | grep -qF -- "$_es"; }; then
      return 0
    fi
  done <<<"$_ALLOWED_LINES"
  return 1
}

# The corrected sites name the replacement in one of two forms, and the form is
# site-specific: four are prose that tell a reader which command to run, while
# two are HTTP User-Agent identifiers, where a hyphenated token is correct
# because a UA is a product string, not an invocation. Asserting one form
# everywhere would force a space into a User-Agent.
_REPLACEMENT_SITES='src/lockfiles/lockfile.schema.json|nucleus-update lockfile
src/vms/NixOS/packer.pkr.hcl|nucleus-update lockfile
src/vms/macOS/packer.pkr.hcl|nucleus-update lockfile
src/platforms/Windows/modules/system/Sync-RedisService.ps1|nucleus-update lockfile
scripts/update.ps1|nucleus-update-lockfile
scripts/update.sh|nucleus-update-lockfile'

# Each corrected site must name the replacement in its own form. Asserting it
# keeps the test honest: a pass that merely deleted the stale words would
# satisfy "no stale reference" while leaving the reader with no instruction.
_replacement_is_named() {
  local _entry _ef _es _missing=0 _first=""
  while IFS= read -r _entry; do
    [ -n "$_entry" ] || continue
    _ef="${_entry%%|*}"
    _es="${_entry#*|}"
    if ! grep -qF -- "$_es" "$REPO_ROOT/$_ef" 2>/dev/null; then
      _missing=$((_missing + 1))
      [ -n "$_first" ] || _first="$_ef (expected '$_es')"
    fi
  done <<<"$_REPLACEMENT_SITES"
  if [ "$_missing" -eq 0 ]; then
    assert_pass "all six corrected sites name the replacement command"
  else
    assert_fail "all six corrected sites name the replacement command" "$_missing of 6 do not, first: $_first"
  fi
}

_no_unexpected_mention_survives() {
  local _hits _file _lineno _line _unapproved _count _first
  _hits="$(git -C "$REPO_ROOT" grep -n -- "$REMOVED" -- . ":(exclude)$_SELF" 2>/dev/null || true)"
  if [ -z "$_hits" ]; then
    assert_pass "no tracked file mentions the removed command $REMOVED"
    return
  fi
  _unapproved=""
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _file="${_line%%:*}"
    _lineno="${_line#*:}"
    _lineno="${_lineno%%:*}"
    _line="${_line#*:}"
    _line="${_line#*:}"
    if ! _is_allowed "$_file" "$_lineno" "$_line"; then
      _unapproved="${_unapproved}${_file}:${_lineno}: ${_line}"$'\n'
    fi
  done <<<"$_hits"
  if [ -z "$_unapproved" ]; then
    assert_pass "every surviving '$REMOVED' mention is an allowlisted historical note"
  else
    _count="$(printf '%s' "$_unapproved" | grep -c . || true)"
    _first="$(printf '%s' "$_unapproved" | head -1)"
    assert_fail "every surviving '$REMOVED' mention is allowlisted" "$_count unapproved, first: $_first"
  fi
}

# The must-not-touch proof. A previous version grepped the whole file for the
# substring, so a reworded line that kept the keyword was both counted as
# present and whitelisted by the very substring under test — circular. This
# compares the pinned line byte-for-byte between the working tree and HEAD: the
# line must exist, must still contain its distinguishing substring, and must be
# identical to the last commit. Reword, delete, reorder or shift it and this
# fails, which is what "must not change" has to mean to be worth asserting.
_allowlist_has_not_rotted() {
  local _entry _ef _en _es _missing=0 _first="" _now _then
  while IFS= read -r _entry; do
    [ -n "$_entry" ] || continue
    _ef="${_entry%%|*}"
    _en="${_entry#*|}"
    _en="${_en%%|*}"
    _es="${_entry#*|}"
    _es="${_es#*|}"
    # WHY tr -d CR: .gitattributes checks these out with CRLF, so the working
    # tree line ends \r while `git show HEAD:` returns the LF blob. Comparing
    # raw bytes calls every CRLF file "changed" and the check would be red for a
    # tree that has not been touched. Normalise both sides to the same text.
    _now="$(sed -n "${_en}p" "$REPO_ROOT/$_ef" 2>/dev/null | tr -d '\r')"
    _then="$(git -C "$REPO_ROOT" show "HEAD:$_ef" 2>/dev/null | sed -n "${_en}p" | tr -d '\r')"
    if [ -z "$_now" ] || [ -z "$_then" ]; then
      _missing=$((_missing + 1))
      [ -n "$_first" ] || _first="$_ef:$_en (line missing)"
    elif [ "$_now" != "$_then" ]; then
      _missing=$((_missing + 1))
      [ -n "$_first" ] || _first="$_ef:$_en (differs from HEAD)"
    elif ! printf '%s' "$_now" | grep -qF -- "$_es"; then
      _missing=$((_missing + 1))
      [ -n "$_first" ] || _first="$_ef:$_en (substring absent)"
    fi
  done <<<"$_ALLOWED_LINES"
  if [ "$_missing" -eq 0 ]; then
    assert_pass "every allowlisted historical note is byte-identical to HEAD"
  else
    assert_fail "every allowlisted historical note is byte-identical to HEAD" \
      "$_missing of 10 changed, first: $_first"
  fi
}

_replacement_is_named
_no_unexpected_mention_survives
_allowlist_has_not_rotted
finish_tests
