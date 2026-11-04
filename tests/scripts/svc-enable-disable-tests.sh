#!/usr/bin/env bash
# Tests for launchctl_service_disable and launchctl_service_enable in
# src/scripts/lib/macos-launch-services.sh, and for the macOS enable/disable
# arms of svc_action in scripts/svc.sh. `launchctl disable` writes a load-time
# gate and changes nothing else, so a running KeepAlive job kept running and the
# verb looked inert; `disable` has to unload the job, `enable` has to clear the
# gate without starting anything, and a launchctl failure has to reach the exit
# status and stderr instead of being swallowed. The fake models launchd, not the
# fix: disable leaves a running job alone, bootout stops it, and a KeepAlive job
# respawns unless the gate was already closed when the bootout arrived.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

ensure_safe_rm_env
init_test_state
# shellcheck source=../../src/scripts/lib/macos-launch-services.sh
. "$SCRIPT_DIR/../../src/scripts/lib/macos-launch-services.sh"

SVC_SH="$REPO_ROOT/scripts/svc.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"

FAKE_LOG="$_tmp/launchctl.log"
FAKE_GATE="$_tmp/gate.state"
FAKE_JOB="$_tmp/job.state"
# FAKE_LABEL is the label the fake reports in its overrides map, so the gate
# probe can read back what disable and enable wrote.
FAKE_LABEL="local.demo"
export FAKE_LOG FAKE_GATE FAKE_JOB FAKE_LABEL

# --- Fake service manager -----------------------------------------------------
# Models only the behaviour the two verbs depend on:
#   disable / enable: rewrite the overrides database and nothing else, which is
#                why the gate alone never stops a running job.
#   bootout:     a KeepAlive job comes back unless the gate is closed at that
#                moment, so a bootout before the gate leaves the job running.
#                FAKE_BOOTOUT_STUCK models an unload that never completes.
#   print:       reports the job while it is loaded.
#   print-disabled: the gate as the overrides map the probe parses.
#   FAKE_DISABLE_FAIL / FAKE_ENABLE_FAIL make the fake report a launchctl error
#                on stderr and exit 1, which is the failure that used to vanish.
cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
_gate() { cat "$FAKE_GATE" 2>/dev/null || printf 'enabled\n'; }
_job() { cat "$FAKE_JOB" 2>/dev/null || printf 'absent\n'; }
case "${1:-}" in
print-disabled)
  printf '\n\tdisabled services = {\n\t\t"%s" => %s\n\t}\n' \
    "${FAKE_LABEL:-local.demo}" "$(_gate)"
  ;;
disable)
  if [ -n "${FAKE_DISABLE_FAIL:-}" ]; then
    printf '%s\n' "$FAKE_DISABLE_FAIL" >&2
    exit 1
  fi
  printf 'disabled\n' >"$FAKE_GATE"
  ;;
enable)
  if [ -n "${FAKE_ENABLE_FAIL:-}" ]; then
    printf '%s\n' "$FAKE_ENABLE_FAIL" >&2
    exit 1
  fi
  printf 'enabled\n' >"$FAKE_GATE"
  ;;
bootout)
  if [ -n "${FAKE_BOOTOUT_STUCK:-}" ]; then
    exit 0
  fi
  if [ "$(_gate)" = "disabled" ]; then
    printf 'absent\n' >"$FAKE_JOB"
  else
    printf 'loaded\n' >"$FAKE_JOB"
  fi
  ;;
bootstrap | start)
  printf 'loaded\n' >"$FAKE_JOB"
  ;;
kill)
  printf 'killed\n' >"$FAKE_JOB"
  ;;
print)
  if [ "$(_job)" = "loaded" ]; then
    printf 'state = running\n\tpid = 4242\n'
  else
    printf 'Could not find service\n' >&2
    exit 113
  fi
  ;;
esac
exit 0
FAKE_LAUNCHCTL
# The sudo prefix a system-scope entry passes stays observable, and the prefix
# itself never reaches the host's sudo.
cat >"$_tmp/bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$FAKE_LOG"
exec "$@"
FAKE_SUDO
# Pinned so the bootout flag branch cannot depend on the host's macOS version.
cat >"$_tmp/bin/sw_vers" <<'FAKE_SW_VERS'
#!/usr/bin/env bash
printf '27.0\n'
FAKE_SW_VERS
# The unload poll sleeps between probes; instant keeps the bounded poll free.
cat >"$_tmp/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/sudo" "$_tmp/bin/sw_vers" "$_tmp/bin/sleep"
PATH="$_tmp/bin:$PATH"
export PATH

_TARGET="gui/501/local.demo"
_DOMAIN="gui/501"
_LABEL="local.demo"

# assert_eq <expected> <actual> <test name>: the shape the plan's test cases use.
assert_eq() { # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3" "expected '$1', got '$2'"
  fi
}

# contains <haystack> <needle>
contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  *) return 1 ;;
  esac
}

# reset_fixture <job state> <gate state>: a fresh job, gate and call log.
reset_fixture() { # <loaded|absent> <enabled|disabled>
  printf '%s\n' "$1" >"$FAKE_JOB"
  printf '%s\n' "$2" >"$FAKE_GATE"
  : >"$FAKE_LOG"
  unset FAKE_DISABLE_FAIL FAKE_ENABLE_FAIL FAKE_BOOTOUT_STUCK
}

gate_state() { # <label>
  cat "$FAKE_GATE"
}

job_state() { # <label>
  cat "$FAKE_JOB"
}

# kill_calls: how many times the fake was signalled, which a disable must never
# need because launchd restarts a killed KeepAlive job.
kill_calls() {
  awk '$1 == "kill" { n++ } END { print n + 0 }' "$FAKE_LOG"
}

# call_order: the state-changing calls in the order they arrived, so the gate
# before the bootout is one string comparison.
call_order() {
  awk '$1 ~ /^(disable|enable|bootout|kill|bootstrap|start)$/ {
    printf "%s%s", sep, $1
    sep = " "
  } END { printf "\n" }' "$FAKE_LOG"
}

# run_disable / run_enable: "rc=<status> out=<output>" so one assertion covers
# both the exit status and the text a caller reports.
run_disable() { # <sudo-prefix>
  local _out _rc=0
  _out=$(launchctl_service_disable "$_TARGET" "${1:-}") || _rc=$?
  printf 'rc=%s out=%s' "$_rc" "$_out"
}

run_enable() { # <sudo-prefix>
  local _out _rc=0
  _out=$(launchctl_service_enable "$_TARGET" "${1:-}") || _rc=$?
  printf 'rc=%s out=%s' "$_rc" "$_out"
}

section 1 "disable sets the gate, then unloads the job"

reset_fixture loaded enabled
_out="$(run_disable)"
assert_eq "rc=0 out=" "$_out" "disable returns 0 and prints nothing on success"
assert_eq "disabled" "$(gate_state demo)" "disable sets the gate"
assert_eq "absent" "$(job_state demo)" "disable leaves the job unloaded"
assert_eq "0" "$(kill_calls)" "disable never needs a separate SIGTERM"
assert_eq "disable bootout" "$(call_order)" \
  "the gate is set before the bootout, because a KeepAlive job respawns in the gap"
assert_eq "disabled" "$(launchctl_service_enabled "$_DOMAIN" "$_LABEL" '')" \
  "the gate a disable writes is what the status probe reads"

section 2 "disable works on a job that is already gone"

reset_fixture absent enabled
assert_eq "rc=0 out=" "$(run_disable)" \
  "disabling an unloaded job succeeds, because the unload is already true"
assert_eq "disabled" "$(gate_state demo)" \
  "disabling an unloaded job still closes the gate"
assert_eq "disable bootout" "$(call_order)" \
  "disabling an unloaded job still asks launchd to unload it"

section 3 "disable reports a failure instead of swallowing it"

reset_fixture loaded enabled
FAKE_DISABLE_FAIL="Could not find domain for domain-target: 5: Input/output error"
export FAKE_DISABLE_FAIL
_alias="$(run_disable)"
if contains "$_alias" "rc=1" && contains "$_alias" \
  "Could not find domain for domain-target: 5: Input/output error"; then
  assert_pass "a failing launchctl disable returns 1 and prints launchctl's reason"
else
  assert_fail "svc-disable-gate-failure" "$_alias"
fi
assert_eq "disable" "$(call_order)" \
  "a gate that could not be written never reaches the bootout"
assert_eq "loaded" "$(job_state demo)" \
  "a failed disable leaves the job's state untouched"

reset_fixture loaded enabled
FAKE_BOOTOUT_STUCK=1
export FAKE_BOOTOUT_STUCK
_alias="$(run_disable)"
if contains "$_alias" "rc=1" && contains "$_alias" "did not unload $_TARGET"; then
  assert_pass "an unload that never completes returns 1 and names the target"
else
  assert_fail "svc-disable-unload-failure" "$_alias"
fi

section 4 "enable clears the gate and starts nothing"

reset_fixture loaded disabled
assert_eq "rc=0 out=" "$(run_enable)" "enable returns 0 and prints nothing on success"
assert_eq "enabled" "$(gate_state demo)" "enable clears the gate"
assert_eq "enable" "$(call_order)" "enable never bootstraps, starts or signals anything"
assert_eq "loaded" "$(job_state demo)" "enable never stops a running job"
assert_eq "enabled" "$(launchctl_service_enabled "$_DOMAIN" "$_LABEL" '')" \
  "the gate an enable writes is what the status probe reads"

reset_fixture absent disabled
assert_eq "rc=0 out=" "$(run_enable)" "enabling while unloaded succeeds"
assert_eq "absent" "$(job_state demo)" "enable never loads an unloaded job"

section 5 "enable reports a failure instead of swallowing it"

reset_fixture loaded disabled
FAKE_ENABLE_FAIL="Could not write configuration: Operation not permitted"
export FAKE_ENABLE_FAIL
_alias="$(run_enable)"
if contains "$_alias" "rc=1" && contains "$_alias" \
  "Could not write configuration: Operation not permitted"; then
  assert_pass "a failing launchctl enable returns 1 and prints launchctl's reason"
else
  assert_fail "svc-enable-gate-failure" "$_alias"
fi
assert_eq "disabled" "$(gate_state demo)" \
  "a failed enable leaves the gate closed"

section 6 "The sudo prefix of a system-scope entry reaches launchctl"

reset_fixture loaded enabled
assert_eq "rc=0 out=" "$(run_disable sudo)" "a system-scope disable succeeds through sudo"
if grep -q "^sudo launchctl disable $_TARGET" "$FAKE_LOG"; then
  assert_pass "the gate command carries the caller's sudo prefix"
else
  assert_fail "svc-disable-sudo-prefix" "log=[$(tr '\n' ';' <"$FAKE_LOG")]"
fi

section 7 "Control: the fake models launchd, so a wrong order is catchable"

# WHY: the ordering assertion above only means something if the fake reproduces
# the two facts the fix exists for. These two cases drive the fake directly,
# without the helpers, to show the job survives the old behaviour.
reset_fixture loaded enabled
launchctl disable "$_TARGET" >/dev/null 2>&1
assert_eq "loaded" "$(job_state demo)" \
  "control: a bare launchctl disable leaves a running job running"

reset_fixture loaded enabled
launchctl bootout "$_TARGET" >/dev/null 2>&1
assert_eq "loaded" "$(job_state demo)" \
  "control: a KeepAlive job respawns when the bootout arrives before the gate"

section 8 "The CLI arms route through the helpers"

# The defect was the two arms in svc_action swallowing launchctl's result, so the
# contract is exercised on the script text: each arm calls its helper, reports the
# failure, and suppresses nothing.
arm_body() { # <action>
  awk -v a="    $1)" 'index($0, a) == 1 { p = 1 } p { print } p && /;;[[:space:]]*$/ { exit }' "$SVC_SH"
}

for _action in enable disable; do
  _arm="$(arm_body "$_action")"
  # Matches an invocation (`launchctl <verb> "$target"`), not the failure message
  # that merely names the command.
  _invocation="launchctl $_action \"\$target\""
  if [ -z "$_arm" ]; then
    assert_fail "the $_action arm of svc_action is defined in scripts/svc.sh" \
      "arm_body $_action returned nothing from $SVC_SH"
  elif ! contains "$_arm" "launchctl_service_$_action"; then
    assert_fail "the $_action arm calls launchctl_service_$_action" "$_arm"
  elif contains "$_arm" "$_invocation"; then
    assert_fail "the $_action arm never calls launchctl $_action directly" "$_arm"
  elif contains "$_arm" ">/dev/null" || contains "$_arm" "2>&1"; then
    assert_fail "the $_action arm suppresses nothing" "$_arm"
  elif ! contains "$_arm" "return 1" || ! contains "$_arm" "error "; then
    assert_fail "the $_action arm reports a failure and returns 1" "$_arm"
  else
    assert_pass "the $_action arm calls launchctl_service_$_action, reports its failure and suppresses nothing"
  fi
done

finish_tests
