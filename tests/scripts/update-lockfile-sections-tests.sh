#!/usr/bin/env bash
# Guard tests for the lockfile section registry used by `nucleus-update lockfile`.
#
# The updater dispatches per lockfile section, and the section list decides which
# sections `--sections` accepts and what `--list-sections` prints.  A section that
# exists in the lockfile but not in the list can never be refreshed (that is how
# the `pi` pins drifted), and the POSIX and PowerShell twins must agree or the two
# platforms update different sets of sections.
#
# Asserted here:
#   * both twins accept the same section list (bash vs pwsh output)
#   * every pinned lockfile section appears in that list
#   * the PowerShell twin carries the list once, not as duplicated literals
#
# Run with: bash tests/scripts/update-lockfile-sections-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "lockfile section registry tests"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
UPDATE_SH="$REPO_ROOT/scripts/update.sh"
UPDATE_PS1="$REPO_ROOT/scripts/update.ps1"
LOCKFILE="$REPO_ROOT/src/lockfiles/lockfile.json"

# Sections the lockfile pins but which are deliberately not updatable by this
# tool: they come from another source (wire them up there, not here).
NOT_REGISTRY_UPDATABLE="suggestions"

section "update-lockfile-sections" "section registry parity"

sh_sections="$(bash "$UPDATE_SH" lockfile --list-sections 2>/dev/null | sort)"
if [ -n "$sh_sections" ]; then
  assert_pass "update.sh --list-sections emits the section list"
else
  assert_fail "update.sh --list-sections emits the section list" "no output"
fi

ps1_sections=""
if command -v pwsh >/dev/null 2>&1; then
  # The PowerShell twin prints a trailing workflow summary; keep only tokens that
  # look like section names (lower-case, dots/dashes, no spaces).
  ps1_sections="$(pwsh -NoProfile -File "$UPDATE_PS1" lockfile -ListSections 2>/dev/null | sed 's/^[^:]*: //' | grep -E '^[A-Za-z0-9.-]+$' | sort)"
  if [ -n "$ps1_sections" ]; then
    assert_pass "update.ps1 -ListSections emits the section list"
  else
    assert_fail "update.ps1 -ListSections emits the section list" "no output"
  fi
  if [ "$sh_sections" = "$ps1_sections" ]; then
    assert_pass "both twins declare the same sections"
  else
    assert_fail "both twins declare the same sections" "sh-only: $(comm -23 <(printf '%s\n' "$sh_sections") <(printf '%s\n' "$ps1_sections") | tr '\n' ' ')|ps1-only: $(comm -13 <(printf '%s\n' "$sh_sections") <(printf '%s\n' "$ps1_sections") | tr '\n' ' ')"
  fi
else
  assert_fail "update.ps1 -ListSections emits the section list" "pwsh not available"
fi

# Every pinned top-level lockfile section must be reachable through the list.
pinned_sections="$(jq -r --arg skip "$NOT_REGISTRY_UPDATABLE" 'keys[] | select(startswith("$") | not) | select(. != "updated") | select(. != "version") | select(. != $skip)' "$LOCKFILE")"
while IFS= read -r pinned; do
  [ -z "$pinned" ] && continue
  case "$pinned" in
  # Nested vm-setup keys are addressed as vm-setup.<key>, which is derived from
  # the parent token; only the parent's presence is asserted here.
  vm-setup) expected="vm-setup" ;;
  *) expected="$pinned" ;;
  esac
  if printf '%s\n' "$sh_sections" | grep -qxF "$expected"; then
    assert_pass "lockfile section '$pinned' is declared in the section list"
  else
    assert_fail "lockfile section '$pinned' is declared in the section list" "missing from update.sh --list-sections"
  fi
done <<EOF
$pinned_sections
EOF

# The PowerShell twin must not carry the list twice again: the duplicate literal
# is what let the two copies drift apart.
ps1_literal_count="$(grep -c "validSectionsCsv = '" "$UPDATE_PS1" || true)"
if [ "$ps1_literal_count" -eq 1 ]; then
  assert_pass "update.ps1 declares the section list exactly once"
else
  assert_fail "update.ps1 declares the section list exactly once" "found $ps1_literal_count assignments"
fi

# The npm-registry sections must be updatable by name: `pi` drifting silently was
# the original defect, so pin the behaviour that both twins know it.
for registry_section in bun pi; do
  if printf '%s\n' "$sh_sections" | grep -qxF "$registry_section"; then
    assert_pass "npm-registry section '$registry_section' is updatable"
  else
    assert_fail "npm-registry section '$registry_section' is updatable" "not declared in update.sh"
  fi
done

finish_tests
