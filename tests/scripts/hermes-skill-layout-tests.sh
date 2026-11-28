#!/usr/bin/env bash
# Nucleus skill bundles live in user scope; Hermes overlays them with relative links.

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT

section 1 "Hermes skill layout"

for name in nucleus-citation-reference nucleus-harness-reference nucleus-platform-reference \
  nucleus-policy-reference nucleus-service-reference nucleus-vm-reference; do
  if test -f "$REPO_ROOT/src/users/default/agents/skills/$name/SKILL.md"; then
    assert_pass "user skill exists: $name"
  else
    assert_fail "user skill exists: $name" "missing src/users/default/agents/skills/$name/SKILL.md"
  fi

  if test ! -e "$REPO_ROOT/.agents/skills/$name"; then
    assert_pass "project skill removed: $name"
  else
    assert_fail "project skill removed: $name" ".agents/skills/$name still exists"
  fi

  link="$REPO_ROOT/src/users/default/hermes/skills/$name"
  if test -L "$link"; then
    assert_pass "hermes skill symlink exists: $name"
  else
    assert_fail "hermes skill symlink exists: $name" "missing symlink $link"
  fi

  if test "$(readlink "$link" 2>/dev/null)" = "../../agents/skills/$name"; then
    assert_pass "hermes skill symlink is relative: $name"
  else
    assert_fail "hermes skill symlink is relative: $name" "got '$(readlink "$link" 2>/dev/null)'"
  fi
done

_entries=0
if [ -d "$REPO_ROOT/src/users/default/hermes/skills" ]; then
  _entries="$(find "$REPO_ROOT/src/users/default/hermes/skills" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
fi
if [ "$_entries" = 6 ]; then
  assert_pass "hermes skills directory holds exactly six entries"
else
  assert_fail "hermes skills directory holds exactly six entries" "found $_entries"
fi

finish_tests
