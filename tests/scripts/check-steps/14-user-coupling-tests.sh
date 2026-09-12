#!/usr/bin/env bash
# shellcheck shell=bash
# Test: no real-user test coupling — tests must not reference production
# src/users/<username>/ directories (except default).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
USERS_ROOT="$REPO_ROOT/src/users"

test_no_real_user_test_coupling() {
  local _errors=0
  local _user_path _user _hit

  for _user_path in "$USERS_ROOT"/*/; do
    [ -d "$_user_path" ] || continue
    _user="$(basename "$_user_path")"
    [ "$_user" = default ] && continue
    while IFS= read -r _hit; do
      [ -z "$_hit" ] && continue
      echo "FAIL: tests must not reference production user '$_user': $_hit"
      _errors=$((_errors + 1))
    done < <(grep -rn -w "$_user" "$TESTS_DIR" 2>/dev/null || true)
  done

  [ "$_errors" -eq 0 ]
}

failures=0
for test_func in test_no_real_user_test_coupling; do
  if ! "$test_func"; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
