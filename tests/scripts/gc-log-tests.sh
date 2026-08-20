#!/usr/bin/env bash
# Tests for nucleus-gc profile-expiry sudo handling and system-log escalation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
EXPIRE_SH="$SCRIPT_DIR/../../src/scripts/lib/expire-profile-generations.sh"
GC_SH="$SCRIPT_DIR/../../scripts/gc.sh"

# Extract a top-level function definition (opening `name() {` through the
# column-0 closing `}`) from a script without executing the script body.
_extract_func() {
  awk -v name="$1" '$0 == name "() {" { p = 1 } p { print } p && $0 == "}" { p = 0; exit }' "$2"
}

# ---- Test A: sudo -H is passed for profile expiry ----

test_sudo_h_passed_when_sudo_true() {
  local mock_dir work
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  cat >"$mock_dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO_CALLED" >> "$MOCK_RECORD"
printf '%s\n' "$@" >> "$MOCK_RECORD"
EOF
  cat >"$mock_dir/nix-env" <<'EOF'
#!/usr/bin/env bash
echo "NIXENV_CALLED" >> "$MOCK_RECORD"
printf '%s\n' "$@" >> "$MOCK_RECORD"
EOF
  chmod +x "$mock_dir/sudo" "$mock_dir/nix-env"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  PATH="$mock_dir:$PATH" NUCLEUS_GC_PROFILE_SUDO=true bash -c '
    . "$1"; . "$2"
    _expire_profile_generations_run_nix_env /nix/var/nix/profiles/system --delete-generations 9999d
  ' nucleus-gc-test "$LIB_SH" "$EXPIRE_SH" >/dev/null 2>&1

  if grep -q 'SUDO_CALLED' "$MOCK_RECORD" && grep -q '\-H' "$MOCK_RECORD" && grep -q 'nix-env' "$MOCK_RECORD"; then
    assert_pass "sudo -H passed to nix-env when NUCLEUS_GC_PROFILE_SUDO=true"
  else
    assert_fail "sudo-h-present" "sudo -H not recorded: $(cat "$MOCK_RECORD")"
  fi
  rm -rf "$mock_dir" "$work"
}

test_nix_env_direct_when_sudo_false() {
  local mock_dir work
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  cat >"$mock_dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO_CALLED" >> "$MOCK_RECORD"
EOF
  cat >"$mock_dir/nix-env" <<'EOF'
#!/usr/bin/env bash
echo "NIXENV_CALLED" >> "$MOCK_RECORD"
printf '%s\n' "$@" >> "$MOCK_RECORD"
EOF
  chmod +x "$mock_dir/sudo" "$mock_dir/nix-env"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  PATH="$mock_dir:$PATH" NUCLEUS_GC_PROFILE_SUDO=false bash -c '
    . "$1"; . "$2"
    _expire_profile_generations_run_nix_env /nix/var/nix/profiles/system --delete-generations 9999d
  ' nucleus-gc-test "$LIB_SH" "$EXPIRE_SH" >/dev/null 2>&1

  if grep -q 'NIXENV_CALLED' "$MOCK_RECORD" && ! grep -q 'SUDO_CALLED' "$MOCK_RECORD"; then
    assert_pass "nix-env invoked directly (no sudo) when NUCLEUS_GC_PROFILE_SUDO=false"
  else
    assert_fail "nixenv-direct" "unexpected record: $(cat "$MOCK_RECORD")"
  fi
  rm -rf "$mock_dir" "$work"
}

# ---- Test B: gc_logs escalates system log dir to root when not writable ----

test_gc_logs_escalates_when_system_dir_not_writable() {
  local mock_dir work user_dir sys_dir gc_func
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  user_dir="$(mktemp -d)"
  sys_dir="$(mktemp -d)"
  # Make the system dir non-writable by the current user to force escalation.
  chmod 555 "$sys_dir"

  cat >"$mock_dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO_CALLED" >> "$MOCK_RECORD"
printf '%s\n' "$@" >> "$MOCK_RECORD"
EOF
  chmod +x "$mock_dir/sudo"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  gc_func="$(_extract_func gc_logs "$GC_SH")"

  PATH="$mock_dir:$PATH" REPO_ROOT="$SCRIPT_DIR/../.." bash -c '
    . "$1"
    nucleus_log_dir() { printf "%s\n" "'"$user_dir"'"; }
    nucleus_system_log_dir() { printf "%s\n" "'"$sys_dir"'"; }
    rotate_logs_in_directory() { echo "ROTATE $1" >> "$MOCK_RECORD"; }
    expire_logs_in_directory() { echo "EXPIRE $1" >> "$MOCK_RECORD"; }
    '"$gc_func"'
    gc_logs
  ' nucleus-gc-test "$LIB_SH" >/dev/null 2>&1

  if grep -q 'log-gc-system.sh' "$MOCK_RECORD" &&
    grep -q "ROTATE $user_dir" "$MOCK_RECORD" &&
    grep -q "EXPIRE $user_dir" "$MOCK_RECORD" &&
    ! grep -qi 'skipping' "$MOCK_RECORD"; then
    assert_pass "gc_logs escalates non-writable system log dir to root via sudo log-gc-system.sh"
  else
    assert_fail "gc-escalate" "unexpected record: $(cat "$MOCK_RECORD")"
  fi
  rm -rf "$mock_dir" "$work" "$user_dir" "$sys_dir"
}

# ---- Test C: gc_logs rotates system log dir inline when writable ----

test_gc_logs_inline_when_system_dir_writable() {
  local mock_dir work user_dir sys_dir gc_func
  mock_dir="$(mktemp -d)"
  work="$(mktemp -d)"
  user_dir="$(mktemp -d)"
  sys_dir="$(mktemp -d)"

  cat >"$mock_dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO_CALLED" >> "$MOCK_RECORD"
EOF
  chmod +x "$mock_dir/sudo"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  gc_func="$(_extract_func gc_logs "$GC_SH")"

  PATH="$mock_dir:$PATH" REPO_ROOT="$SCRIPT_DIR/../.." bash -c '
    . "$1"
    nucleus_log_dir() { printf "%s\n" "'"$user_dir"'"; }
    nucleus_system_log_dir() { printf "%s\n" "'"$sys_dir"'"; }
    rotate_logs_in_directory() { echo "ROTATE $1" >> "$MOCK_RECORD"; }
    expire_logs_in_directory() { echo "EXPIRE $1" >> "$MOCK_RECORD"; }
    '"$gc_func"'
    gc_logs
  ' nucleus-gc-test "$LIB_SH" >/dev/null 2>&1

  if grep -q "ROTATE $sys_dir" "$MOCK_RECORD" &&
    grep -q "EXPIRE $sys_dir" "$MOCK_RECORD" &&
    ! grep -q 'SUDO_CALLED' "$MOCK_RECORD"; then
    assert_pass "gc_logs rotates writable system log dir inline (no escalation)"
  else
    assert_fail "gc-inline" "unexpected record: $(cat "$MOCK_RECORD")"
  fi
  rm -rf "$mock_dir" "$work" "$user_dir" "$sys_dir"
}

# ---- Run tests ----

section 1 "gc log tests"
echo ""

test_sudo_h_passed_when_sudo_true
test_nix_env_direct_when_sudo_false
test_gc_logs_escalates_when_system_dir_not_writable
test_gc_logs_inline_when_system_dir_writable

echo ""
echo "--- gc log tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
