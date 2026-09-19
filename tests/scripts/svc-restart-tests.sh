#!/usr/bin/env bash
# Tests for the launchd unload/bootstrap handoff in
# src/scripts/lib/macos-launch-services.sh — the macOS >= 26 asynchronous
# `bootout` race that left a managed service unloaded and silent: `bootstrap`
# issued right after `bootout` fails with "Bootstrap failed: 5: Input/output
# error" because the job is still loaded, and the pending unload then removes it
# for good. Assertions describe that contract, not what this host happens to run.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/macos-launch-services.sh
. "$SCRIPT_DIR/../../src/scripts/lib/macos-launch-services.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"

FAKE_LOG="$_tmp/launchctl.log"
FAKE_STATE="$_tmp/job.state"
FAKE_PENDING="$_tmp/bootout.pending"
FAKE_BOOTSTRAP_CALLS="$_tmp/bootstrap.calls"
export FAKE_LOG FAKE_STATE FAKE_PENDING FAKE_BOOTSTRAP_CALLS

# --- Fake service manager -----------------------------------------------------
# Models only the behaviour the race depends on.
#   print      — reports the job while `state` is `loaded`; a pending unload
#                (`FAKE_BOOTOUT_DELAY` probes) flips the state to `absent` once
#                it is spent, which is how an asynchronous `bootout` looks.
#   bootout    — queues that pending unload instead of completing immediately.
#   bootstrap  — returns the real macOS code 5 when the job is still loaded, and
#                loads it otherwise. FAKE_CONFLICT_ONCE limits that to the first
#                attempt (the case where `print` cannot see the real state and
#                only a retry saves the reload), and FAKE_BOOTSTRAP_FAIL forces a
#                non-race failure whose message must survive to the caller.
#   sleep      — instant so the bounded poll costs no wall-clock time.
cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
state="$(cat "$FAKE_STATE" 2>/dev/null || printf 'absent\n')"
case "${1:-}" in
bootout)
  if [ "${FAKE_BOOTOUT_DELAY:-0}" -gt 0 ]; then
    printf '%s\n' "$FAKE_BOOTOUT_DELAY" >"$FAKE_PENDING"
    exit 0
  fi
  printf 'absent\n' >"$FAKE_STATE"
  [ "$state" = loaded ] || exit 3
  exit 0
  ;;
bootstrap)
  n="$(cat "$FAKE_BOOTSTRAP_CALLS" 2>/dev/null || printf '0\n')"
  printf '%s\n' "$((n + 1))" >"$FAKE_BOOTSTRAP_CALLS"
  if [ -n "${FAKE_BOOTSTRAP_FAIL:-}" ]; then
    printf '%s\n' "$FAKE_BOOTSTRAP_FAIL" >&2
    exit 2
  fi
  if [ "$state" = loaded ] || { [ "${FAKE_CONFLICT_ONCE:-0}" = "1" ] && [ "$n" = "0" ]; }; then
    printf 'Bootstrap failed: 5: Input/output error\n' >&2
    exit 5
  fi
  printf 'loaded\n' >"$FAKE_STATE"
  exit 0
  ;;
print)
  if [ "$state" = absent ] || [ "${FAKE_PRINT_LIES:-0}" = "1" ]; then
    printf 'Could not find service\n' >&2
    exit 113
  fi
  printf 'state = running\n\tpid = 4242\n'
  pending="$(cat "$FAKE_PENDING" 2>/dev/null || printf '0\n')"
  if [ "$pending" -gt 0 ]; then
    pending=$((pending - 1))
    printf '%s\n' "$pending" >"$FAKE_PENDING"
    [ "$pending" -eq 0 ] && printf 'absent\n' >"$FAKE_STATE"
  fi
  exit 0
  ;;
esac
exit 0
FAKE_LAUNCHCTL
cat >"$_tmp/bin/sw_vers" <<'FAKE_SW_VERS'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SW_VERS:-27.0}"
FAKE_SW_VERS
cat >"$_tmp/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FAKE_LOG"
FAKE_SLEEP
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/sw_vers" "$_tmp/bin/sleep"
PATH="$_tmp/bin:$PATH"
export PATH

_TARGET="gui/501/local.cloud-mount.OneDrive"
_PLIST="/Users/example/Library/LaunchAgents/local.cloud-mount.OneDrive.plist"
_DOMAIN="gui/501"

# reset_fixture <loaded|absent> — fresh fake state and call log per assertion.
reset_fixture() { # <state>
  printf '%s\n' "$1" >"$FAKE_STATE"
  printf '0\n' >"$FAKE_PENDING"
  : >"$FAKE_LOG"
  rm -f "$FAKE_BOOTSTRAP_CALLS"
  unset FAKE_BOOTOUT_DELAY FAKE_CONFLICT_ONCE FAKE_PRINT_LIES FAKE_SW_VERS
  unset FAKE_BOOTSTRAP_FAIL
}

bootstrap_calls() {
  if [ -f "$FAKE_BOOTSTRAP_CALLS" ]; then
    cat "$FAKE_BOOTSTRAP_CALLS"
  else
    printf '0\n'
  fi
}

# count_calls <command> — how many times the fake recorded that command.
count_calls() {
  awk -v pat="^$1" '$0 ~ pat { n++ } END { print n + 0 }' "$FAKE_LOG"
}

# contains <text> <needle> — substring test, kept out of an `if` condition so
# the surrounding `case` cannot be confused with shfmt's list parsing.
contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  *) return 1 ;;
  esac
}

# assert_rc <slug> <expected rc> <actual rc>
assert_rc() { # <slug> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected rc=$2, got rc=$3"
  fi
}

section 1 "Job loaded probe"

reset_fixture loaded
_rc=0
launchctl_job_loaded "$_TARGET" "" || _rc=$?
assert_rc "a loaded job is reported as loaded" 0 "$_rc"
reset_fixture absent
_rc=0
launchctl_job_loaded "$_TARGET" "" || _rc=$?
if [ "$_rc" -ne 0 ]; then
  assert_pass "an absent job is reported as unloaded"
else
  assert_fail "svc-job-loaded-probe" "an absent job was reported as loaded"
fi

section 2 "Unload waits for the job to disappear"

reset_fixture loaded
FAKE_BOOTOUT_DELAY=2
# WHY: the fake flags are read by the fake launchctl/sw_vers child processes,
# so every one of them has to be exported.
export FAKE_BOOTOUT_DELAY
_rc=0
launchctl_bootout_wait "$_TARGET" "" || _rc=$?
if [ "$_rc" -eq 0 ] && grep -q '^bootout --wait ' "$FAKE_LOG" && [ "$(count_calls print)" -ge 3 ]; then
  assert_pass "macOS 26+ unloads with bootout --wait and polls until the job is gone"
else
  assert_fail "svc-bootout-wait-flag" \
    "rc=$_rc log=[$(tr '\n' ';' <"$FAKE_LOG")]"
fi

reset_fixture loaded
FAKE_SW_VERS=15.0
unset FAKE_BOOTOUT_DELAY
export FAKE_SW_VERS
_rc=0
launchctl_bootout_wait "$_TARGET" "" || _rc=$?
if [ "$_rc" -eq 0 ] && ! grep -q -- '--wait' "$FAKE_LOG"; then
  assert_pass "pre-26 macOS never passes an unsupported --wait flag"
else
  assert_fail "svc-bootout-pre26" "rc=$_rc log=[$(tr '\n' ';' <"$FAKE_LOG")]"
fi

reset_fixture loaded
FAKE_BOOTOUT_DELAY=999
export FAKE_BOOTOUT_DELAY
_rc=0
launchctl_bootout_wait "$_TARGET" "" || _rc=$?
assert_rc "a job that never unloads reports failure instead of looping" 1 "$_rc"

reset_fixture absent
unset FAKE_BOOTOUT_DELAY
_rc=0
launchctl_bootout_wait "$_TARGET" "" || _rc=$?
assert_rc "an already unloaded job still reports the unload as complete" 0 "$_rc"

section 3 "Bootstrap handoff"

reset_fixture loaded
_rc=0
_out="$(launchctl_bootstrap_plist "$_DOMAIN" "$_PLIST" "$_TARGET" "")" || _rc=$?
if [ "$_rc" -eq 0 ] && [ -z "$_out" ] && [ "$(bootstrap_calls)" = "0" ]; then
  assert_pass "an already-loaded job is success, never a second bootstrap"
else
  assert_fail "svc-bootstrap-loaded" "rc=$_rc calls=$(bootstrap_calls) out=[$_out]"
fi

reset_fixture absent
_rc=0
_out="$(launchctl_bootstrap_plist "$_DOMAIN" "$_PLIST" "$_TARGET" "")" || _rc=$?
if [ "$_rc" -eq 0 ] && [ -z "$_out" ] && [ "$(bootstrap_calls)" = "1" ]; then
  assert_pass "an unloaded job is bootstrapped once and silently"
else
  assert_fail "svc-bootstrap-absent" "rc=$_rc calls=$(bootstrap_calls) out=[$_out]"
fi

reset_fixture absent
# WHY: `print` cannot see the real state here, so the retry has to save the
# reload; without it the reload would be reported as broken.
FAKE_PRINT_LIES=1
FAKE_CONFLICT_ONCE=1
export FAKE_PRINT_LIES FAKE_CONFLICT_ONCE
_rc=0
_out="$(launchctl_bootstrap_plist "$_DOMAIN" "$_PLIST" "$_TARGET" "")" || _rc=$?
if [ "$_rc" -eq 0 ] && [ "$(bootstrap_calls)" = "2" ]; then
  assert_pass "code 5 from a still-loaded job is retried after the unload"
else
  assert_fail "svc-bootstrap-conflict-retry" \
    "rc=$_rc calls=$(bootstrap_calls) out=[$_out] log=[$(tr '\n' ';' <"$FAKE_LOG")]"
fi

reset_fixture absent
FAKE_BOOTSTRAP_FAIL="Bootstrap failed: 2: No such file or directory"
export FAKE_BOOTSTRAP_FAIL
_rc=0
_out="$(launchctl_bootstrap_plist "$_DOMAIN" "$_PLIST" "$_TARGET" "")" || _rc=$?
if [ "$_rc" -eq 1 ] && [ "$(bootstrap_calls)" = "1" ] &&
  contains "$_out" "Bootstrap failed: 2: No such file or directory"; then
  assert_pass "a real failure keeps launchctl's message for the caller to report"
else
  assert_fail "svc-bootstrap-failure-visible" \
    "rc=$_rc calls=$(bootstrap_calls) out=[$_out]"
fi

section 4 "Reload goes through the helper"

# WHY: grep-only — the defect was a call site that swallowed the bootstrap
# result, so the contract under test is "every call site reloads through the
# helper". The pattern matches an invocation (an argument follows launchctl)
# and not a message that merely names the command.
_reload_invocation="launchctl (bootstrap|bootout)( --wait)? [\"'$]"
for _site in scripts/svc.sh src/scripts/services/service-watchdog.sh src/scripts/services/caddy-trust.sh; do
  _body="$(cat "$REPO_ROOT/$_site")"
  if ! contains "$_body" "launchctl_bootout_wait" || ! contains "$_body" "launchctl_bootstrap_plist"; then
    assert_fail "svc-reload-through-helper" "$(basename "$_site") does not reload through both shared helpers"
  elif grep -qE "$_reload_invocation" "$REPO_ROOT/$_site"; then
    assert_fail "svc-reload-through-helper" "$(basename "$_site") still invokes launchctl bootstrap/bootout directly"
  else
    assert_pass "$(basename "$_site") routes every reload through the shared helper"
  fi
done

finish_tests
