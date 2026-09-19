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

section 5 "A reload waits for the cloud mount to be released"

# assert_count <slug> <expected> <actual>; assert_mentions <slug> <haystack> <needle>
# WHY: this suite asserts through assert_rc/contains, so the CLI section uses the
# same helpers rather than introducing a second assertion style.
assert_count() { # <slug> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected $2, got $3"
  fi
}

assert_mentions() { # <slug> <haystack> <needle>
  if contains "$2" "$3"; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected output to mention '$3', got: $2"
  fi
}

# WHY: the ordering under test lives inside scripts/svc.sh (stop the mount, wait
# until the volume left the mount table, only then bootout+bootstrap), so the
# contract is exercised through the CLI: a stub registry, the shared user-registry
# fixture, and fakes that append every call to ONE timeline, which is what makes
# the order of a mount probe and a bootstrap observable.
_cli="$_tmp/cli"
mkdir -p "$_cli/repo/src/modules" "$_cli/bin" "$_cli/home" "$_cli/log"
ln -sfn "$REPO_ROOT/tests/fixtures/user-registry/src/users" "$_cli/repo/src/users"
cat >"$_cli/repo/src/modules/services.json" <<JSON
{
  "\$logging": { "MacBook": { "logDir": "$_cli/log", "systemLogDir": "$_cli/syslog" } },
  "cloud-drive": {
    "displayName": "Cloud Drive Mounts",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "prefixMatch": true,
        "service": "local.cloud-mount.",
        "scope": "user",
        "launchdDomain": "gui"
      }
    }
  },
  "plain-service": {
    "displayName": "Plain Service",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "service": "local.plain",
        "scope": "user",
        "launchdDomain": "gui"
      }
    }
  }
}
JSON

FAKE_TIMELINE="$_cli/timeline.log"
FAKE_CLI_STATE="$_cli/job.state"
FAKE_MOUNT_CALLS="$_cli/mount.calls"
export FAKE_TIMELINE FAKE_CLI_STATE FAKE_MOUNT_CALLS

cat >"$_cli/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
_state="$(cat "${FAKE_CLI_STATE:?}" 2>/dev/null || printf 'stopped\n')"
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LIVE:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  case "$_state" in
  running)
    printf 'state = running\n\tpid = 4242\n'
    ;;
  absent)
    printf 'Could not find service\n' >&2
    exit 113
    ;;
  *)
    printf 'state = not running\n\tlast exit code = 0\n'
    ;;
  esac
  ;;
kill)
  printf 'kill %s\n' "${*: -1}" >>"${FAKE_TIMELINE:?}"
  [ "${FAKE_KILL_FAIL:-}" = 1 ] && exit 1
  printf 'stopped\n' >"$FAKE_CLI_STATE"
  ;;
bootout)
  printf 'bootout %s\n' "${*: -1}" >>"${FAKE_TIMELINE:?}"
  printf 'absent\n' >"$FAKE_CLI_STATE"
  ;;
bootstrap)
  printf 'bootstrap %s\n' "${*: -1}" >>"${FAKE_TIMELINE:?}"
  printf 'running\n' >"$FAKE_CLI_STATE"
  ;;
enable | disable | start | kickstart)
  printf '%s %s\n' "$1" "${*: -1}" >>"${FAKE_TIMELINE:?}"
  ;;
esac
exit 0
FAKE

# The mount table: FAKE_MOUNT_RELEASE_AFTER makes it stop listing the path after
# that many probes, which is the shape of a volume that finishes unmounting.
cat >"$_cli/bin/mount" <<'FAKE'
#!/usr/bin/env bash
_outcome="${FAKE_MOUNT_TABLE:-}"
if [ -n "${FAKE_MOUNT_RELEASE_AFTER:-}" ] && [ -n "$_outcome" ]; then
  _calls=0
  [ -f "${FAKE_MOUNT_CALLS:?}" ] && _calls="$(cat "$FAKE_MOUNT_CALLS")"
  _calls=$((_calls + 1))
  printf '%s' "$_calls" >"$FAKE_MOUNT_CALLS"
  [ "$_calls" -gt "$FAKE_MOUNT_RELEASE_AFTER" ] && _outcome=""
fi
printf 'mount: %s\n' "${_outcome:-released}" >>"${FAKE_TIMELINE:?}"
if [ -n "$_outcome" ]; then printf '%s\n' "$_outcome"; fi
exit 0
FAKE

# Instant: the release wait polls on sleep, so its 30 s bound must not become
# 30 s of wall clock in this suite.
cat >"$_cli/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$_cli/bin/launchctl" "$_cli/bin/mount" "$_cli/bin/sleep"

# run_cli — Run the CLI against the stub registry with the fakes on PATH.
run_cli() { # <svc.sh args...>
  env NUCLEUS_HOST=MacBook \
    NUCLEUS_REPO_ROOT="$_cli/repo" \
    NUCLEUS_SERVICES_JSON="$_cli/repo/src/modules/services.json" \
    HOME="$_cli/home" \
    NUCLEUS_LOG_DIR="$_cli/log" \
    SUDO_USER=test-user \
    PATH="$_cli/bin:$_tmp/bin:$PATH" \
    FAKE_LIVE="${FAKE_LIVE:-}" \
    FAKE_MOUNT_TABLE="${FAKE_MOUNT_TABLE:-}" \
    FAKE_MOUNT_RELEASE_AFTER="${FAKE_MOUNT_RELEASE_AFTER:-}" \
    FAKE_KILL_FAIL="${FAKE_KILL_FAIL:-}" \
    bash "$REPO_ROOT/scripts/svc.sh" "$@"
}

reset_cli() { # <job state> <mount table> <release after>
  printf '%s\n' "$1" >"$FAKE_CLI_STATE"
  FAKE_MOUNT_TABLE="$2"
  FAKE_MOUNT_RELEASE_AFTER="$3"
  : >"$FAKE_TIMELINE"
  : >"$FAKE_MOUNT_CALLS"
  captured_status=0
  captured_output="$(run_cli "${@:4}" 2>&1)" || captured_status=$?
}

# timeline_index — First line number of a timeline entry (0 when absent).
timeline_index() { # <substring>
  awk -v pat="$1" 'index($0, pat) { print NR; exit } END { if (NR == 0) print 0 }' "$FAKE_TIMELINE"
}

_cli_mount="fake://vol on $_cli/home/clouds/iCloud (fake, nodev)"
FAKE_LIVE="local.cloud-mount.iCloud"

reset_cli stopped "$_cli_mount" 2 restart local.cloud-mount.iCloud
assert_count "restarting a cloud mount exits 0" 0 "$captured_status"
assert_count "the reload bootstraps the instance once" 1 "$(grep -c '^bootstrap' "$FAKE_TIMELINE")"
_released="$(timeline_index 'mount: released')"
_bootstrap="$(timeline_index 'bootstrap')"
if [ "$_released" -gt 0 ] && [ "$_bootstrap" -gt "$_released" ]; then
  assert_pass "the reload starts only after the volume left the mount table"
else
  assert_fail "svc-reload-waits-for-mount" \
    "released=$_released bootstrap=$_bootstrap timeline=[$(tr '\n' ';' <"$FAKE_TIMELINE")]"
fi
_kill="$(timeline_index 'kill')"
if [ "$_kill" -gt 0 ] && [ "$_released" -gt "$_kill" ]; then
  assert_pass "the volume is released after the mount is stopped"
else
  assert_fail "svc-stop-before-release-wait" \
    "kill=$_kill released=$_released timeline=[$(tr '\n' ';' <"$FAKE_TIMELINE")]"
fi

section 6 "A mount that never releases blocks the reload"

reset_cli running "$_cli_mount" "" restart local.cloud-mount.iCloud
assert_count "a mount that never releases fails the restart" 1 "$captured_status"
assert_mentions "the stale volume is reported" "$captured_output" "still mounted"
assert_count "a stale volume is never reloaded over" 0 "$(grep -c '^bootstrap' "$FAKE_TIMELINE")"

section 7 "Stop waits for release; an ordinary service never probes the table"

reset_cli running "$_cli_mount" 1 stop local.cloud-mount.iCloud
assert_count "stopping a cloud mount exits 0" 0 "$captured_status"
assert_count "stopping a cloud mount kills the job" 1 "$(grep -c '^kill' "$FAKE_TIMELINE")"
assert_count "stopping a cloud mount never bootstraps" 0 "$(grep -c '^bootstrap' "$FAKE_TIMELINE")"
if [ "$(timeline_index 'mount: released')" -gt 0 ]; then
  assert_pass "stopping waits for the volume to be released"
else
  assert_fail "svc-stop-waits-for-mount" "timeline=[$(tr '\n' ';' <"$FAKE_TIMELINE")]"
fi

FAKE_KILL_FAIL=1
reset_cli running "$_cli_mount" 1 stop local.cloud-mount.iCloud
assert_count "a stop whose mount kill failed still reports the failure" 1 "$captured_status"
if [ "$(timeline_index 'mount: released')" -gt 0 ]; then
  assert_pass "the failed stop still waited for the volume to be released"
else
  assert_fail "svc-stop-failure-still-waits" "timeline=[$(tr '\n' ';' <"$FAKE_TIMELINE")]"
fi
FAKE_KILL_FAIL=

reset_cli running "$_cli_mount" "" stop plain-service
assert_count "stopping an ordinary service exits 0" 0 "$captured_status"
assert_count "an ordinary service never probes the mount table" 0 "$(grep -c '^mount:' "$FAKE_TIMELINE")"

finish_tests
