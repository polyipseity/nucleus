#!/usr/bin/env bash
# Tests for nucleus-gc profile-expiry sudo handling, system-log escalation, and
# how log-gc.sh resolves the nucleus-logs entry point.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
EXPIRE_SH="$SCRIPT_DIR/../../src/scripts/lib/expire-profile-generations.sh"
GC_SH="$SCRIPT_DIR/../../scripts/gc.sh"
LOG_GC_SH="$SCRIPT_DIR/../../src/scripts/services/log-gc.sh"

ensure_safe_rm_env
init_test_state

# new_logs_stub <dir>: create the NUCLEUS_LOGS_BIN stand-in. gc_logs delegates
# rotation and expiry to nucleus-logs, so the suite stubs that entry point and
# records the operation and the resolved directory; the library functions it
# drives are never reached here.
new_logs_stub() {
  cat >"$1/logs-stub.sh" <<'EOF'
#!/usr/bin/env bash
_action="$1"
_scope=user
while [ "$#" -gt 0 ]; do
  case "$1" in
  --scope)
    _scope="$2"
    shift
    ;;
  esac
  shift
done
case "$_scope" in
system) _dir="$STUB_SYSTEM_DIR" ;;
*) _dir="$STUB_USER_DIR" ;;
esac
printf '%s %s\n' "$(printf '%s' "$_action" | tr '[:lower:]' '[:upper:]')" "$_dir" >>"$MOCK_RECORD"
EOF
  chmod +x "$1/logs-stub.sh"
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
  new_logs_stub "$mock_dir"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  gc_func="$(extract_func gc_logs "$GC_SH")"

  PATH="$mock_dir:$PATH" REPO_ROOT="$SCRIPT_DIR/../.." \
    NUCLEUS_LOGS_BIN="$mock_dir/logs-stub.sh" \
    STUB_USER_DIR="$user_dir" STUB_SYSTEM_DIR="$sys_dir" bash -c '
    . "$1"
    nucleus_log_dir() { printf "%s\n" "'"$user_dir"'"; }
    nucleus_system_log_dir() { printf "%s\n" "'"$sys_dir"'"; }
    '"$gc_func"'
    gc_logs
  ' nucleus-gc-test "$LIB_SH" >/dev/null 2>&1

  # The mock sudo records one argument per line, so the script path and the
  # scope selector are asserted separately.
  if grep -q 'services/log-gc\.sh$' "$MOCK_RECORD" &&
    grep -qx 'system' "$MOCK_RECORD" &&
    grep -q "ROTATE $user_dir" "$MOCK_RECORD" &&
    grep -q "EXPIRE $user_dir" "$MOCK_RECORD" &&
    ! grep -qi 'skipping' "$MOCK_RECORD"; then
    assert_pass "gc_logs escalates non-writable system log dir to root via sudo log-gc.sh system"
  else
    assert_fail "gc-escalate" "unexpected record: $(cat "$MOCK_RECORD")"
  fi
  # Restore the mode before the cleanup removes the directory: safe-rm moves a
  # deletion into the trash, and macOS refuses to rename a 0555 directory into
  # any trash directory at all, so the cleanup would abort the suite before its
  # tally. The suite made the directory unreadable, so undoing that is its job.
  chmod u+w "$sys_dir"
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
  new_logs_stub "$mock_dir"
  export MOCK_RECORD="$work/record.txt"
  : >"$MOCK_RECORD"

  gc_func="$(extract_func gc_logs "$GC_SH")"

  PATH="$mock_dir:$PATH" REPO_ROOT="$SCRIPT_DIR/../.." \
    NUCLEUS_LOGS_BIN="$mock_dir/logs-stub.sh" \
    STUB_USER_DIR="$user_dir" STUB_SYSTEM_DIR="$sys_dir" bash -c '
    . "$1"
    nucleus_log_dir() { printf "%s\n" "'"$user_dir"'"; }
    nucleus_system_log_dir() { printf "%s\n" "'"$sys_dir"'"; }
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

# ---- Test D: log-gc.sh resolves the log app when the seam is unset ----

test_log_gc_uses_root_scripts_when_bin_unset() {
  local work fixture rc record
  work="$(mktemp -d)"
  fixture="$work/repo"
  mkdir -p "$fixture/scripts"
  cat >"$fixture/scripts/logs.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG_GC_RECORD"
EOF
  chmod +x "$fixture/scripts/logs.sh"
  export LOG_GC_RECORD="$work/record.txt"
  : >"$LOG_GC_RECORD"

  rc=0
  (unset NUCLEUS_LOGS_BIN && NUCLEUS_REPO_ROOT="$fixture" bash "$LOG_GC_SH" user) || rc=$?
  record="$(cat "$LOG_GC_RECORD")"

  if [ "$rc" -eq 0 ] && [ "$record" = "gc --scope user" ]; then
    assert_pass "log-gc.sh runs the checkout's logs app when NUCLEUS_LOGS_BIN is unset"
  else
    assert_fail "log-gc-root" "rc=$rc record: $record"
  fi
  unset LOG_GC_RECORD
  rm -rf "$work"
}

# ---- Test E: log-gc.sh refuses to guess the log app ----

test_log_gc_dies_without_root() {
  local work tree err rc
  work="$(mktemp -d)"
  tree="$work/tree/src/scripts"
  mkdir -p "$tree/services" "$tree/lib"
  cp "$LOG_GC_SH" "$tree/services/log-gc.sh"
  cp "$LIB_SH" "$tree/lib/lib.sh"

  # The copy sits outside the checkout and git is kept below it, so every source
  # derive_repo_root consults is absent or rejected.
  rc=0
  err="$(cd "$work" && unset NUCLEUS_REPO_ROOT && GIT_CEILING_DIRECTORIES="$work" \
    NUCLEUS_REPO_ROOT_SYSTEM_FILE="$work/absent-repo-root" \
    bash "$tree/services/log-gc.sh" user 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -ne 0 ] && grep -q 'NUCLEUS_LOGS_BIN' <<<"$err" && grep -q 'repo-root' <<<"$err"; then
    assert_pass "log-gc.sh fails and names NUCLEUS_LOGS_BIN when the root is unresolvable"
  else
    assert_fail "log-gc-unresolvable" "rc=$rc stderr: $err"
  fi
  rm -rf "$work"
}

# ---- Run tests ----

section 1 "gc log tests"
echo ""

test_sudo_h_passed_when_sudo_true
test_nix_env_direct_when_sudo_false
test_gc_logs_escalates_when_system_dir_not_writable
test_gc_logs_inline_when_system_dir_writable
test_log_gc_uses_root_scripts_when_bin_unset
test_log_gc_dies_without_root

finish_tests
