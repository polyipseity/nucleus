#!/usr/bin/env bash
# Tests for svc_action_warning in scripts/svc.sh and for the stop/start switches
# --disable and --enable. A stop that the service manager undoes looks like a
# success, so the warning names the platform mechanism and the remedy flag. The
# table below is the contract: a macos-launchctl entry without onDemand warns,
# while an onDemand entry and a nixos-systemctl unit stay silent. start warns
# whenever the enabled probe named the service disabled. Windows rows live in
# svc.ps1, which is the CLI that serves those entry types.
#
# The flag cases run the real CLI against a stub registry and a fake launchctl
# that models the unload and the gate, so argument order, rejection on the wrong
# action and call order are observed end to end rather than on script text.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

ensure_safe_rm_env
init_test_state

require_command jq "the warning helper reads the entry JSON with jq"

SVC_SH="$REPO_ROOT/scripts/svc.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

# contains <haystack> <needle>
contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  *) return 1 ;;
  esac
}

assert_eq() { # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3" "expected '$1', got '$2'"
  fi
}

# warning <action> <entry-json> [enabled]: the helper's output, with the optional
# third argument forwarded only when supplied so its default stays covered.
warning() { # <action> <entry-json> [enabled]
  if [ "$#" -gt 2 ]; then
    svc_action_warning "$1" "$2" "$3"
  else
    svc_action_warning "$1" "$2"
  fi
}

section 1 "stop warns only where the platform brings the service back"

WARNING_FUNC="$(extract_func svc_action_warning "$SVC_SH")"
if [ -z "$WARNING_FUNC" ]; then
  assert_fail "svc_action_warning is defined in scripts/svc.sh" \
    "extract_func svc_action_warning returned nothing from $SVC_SH"
  finish_tests
fi
eval "$WARNING_FUNC"

macos_entry='{"type":"macos-launchctl","service":"local.demo","scope":"user","launchdDomain":"gui"}'
macos_ondemand='{"type":"macos-launchctl","service":"local.demo","scope":"user","launchdDomain":"gui","onDemand":true}'
schtask_absent='{"type":"windows-schtask","taskPath":"\\nucleus\\demo"}'
systemctl_entry='{"type":"nixos-systemctl","service":"demo.service","scope":"system"}'

_macos_stop="$(warning stop "$macos_entry")"
if contains "$_macos_stop" "--disable" && contains "$_macos_stop" "launchd"; then
  assert_pass "a persistent launchd job warns that launchd restarts it and names --disable"
else
  assert_fail "a persistent launchd job warns that launchd restarts it and names --disable" "$_macos_stop"
fi

assert_eq "" "$(warning stop "$macos_ondemand")" \
  "an onDemand launchd entry is silent, because it is started explicitly"

_schtask_stop="$(warning stop "$schtask_absent")"
assert_eq "" "$_schtask_stop" \
  "a Windows entry is silent here, because svc.ps1 owns the Windows consequence table"

assert_eq "" "$(warning stop "$systemctl_entry")" \
  "a systemd unit is silent, because systemd honors an explicit stop"

assert_eq "" "$(warning stop '{"type":"something-else"}')" \
  "an unknown service type is silent rather than claiming a consequence"

section 2 "start warns whenever the probe named the service disabled"

for _type_entry in "$macos_entry" "$systemctl_entry"; do
  _type="$(printf '%s' "$_type_entry" | jq -r '.type')"
  _start_warning="$(warning start "$_type_entry" false)"
  if contains "$_start_warning" "--enable" && contains "$_start_warning" "not enabled"; then
    assert_pass "start on a disabled $_type names --enable"
  else
    assert_fail "start on a disabled $_type names --enable" "$_start_warning"
  fi
done

assert_eq "" "$(warning start "$macos_entry" true)" \
  "start on an enabled service is silent"
assert_eq "" "$(warning start "$macos_entry" "")" \
  "start on an unknown enabled state is silent, because no read claimed it"
assert_eq "" "$(warning start "$macos_entry")" \
  "start without an enabled verdict is silent"

section 3 "The switches parse in both orders and reject the wrong action"

mkdir -p "$_tmp/repo/src/modules" "$_tmp/bin" "$_tmp/home" "$_tmp/log"
cat >"$_tmp/repo/src/modules/services.json" <<JSON
{
  "\$logging": {
    "MacBook": {
      "logDir": "$_tmp/log",
      "systemLogDir": "$_tmp/syslog"
    }
  },
  "demo": {
    "displayName": "Demo",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "service": "local.demo",
        "scope": "user",
        "launchdDomain": "gui"
      }
    }
  },
  "demo-ondemand": {
    "displayName": "Demo On Demand",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "service": "local.demo-ondemand",
        "scope": "user",
        "launchdDomain": "gui",
        "onDemand": true
      }
    }
  }
}
JSON

FAKE_LOG="$_tmp/launchctl.log"
FAKE_STATE="$_tmp/job.state"
FAKE_GATE="$_tmp/gate.state"
export FAKE_LOG FAKE_STATE FAKE_GATE

# Models only what the switch cases observe: the unload dropped the label only
# when the gate was already closed, so a disable that ran before the stop would
# leave the job loaded, and bootstrap/start load it. sw_vers is pinned so the
# bootout flag does not depend on this host's macOS version, and sleep is instant
# so the unload poll costs no wall-clock time.
cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
_state() { cat "$FAKE_STATE" 2>/dev/null || printf 'absent\n'; }
_gate() { cat "$FAKE_GATE" 2>/dev/null || printf 'enabled\n'; }
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  if [ "$(_state)" = "loaded" ]; then printf '4242\t0\tlocal.demo\n'; fi
  ;;
print)
  if [ "$(_state)" = "loaded" ]; then
    printf 'state = running\n\tpid = 4242\n'
  else
    printf 'Could not find service\n' >&2
    exit 113
  fi
  ;;
print-disabled)
  printf '\n\tdisabled services = {\n'
  if [ "$(_gate)" = "disabled" ]; then
    printf '\t\t"local.demo" => disabled\n\t\t"local.demo-ondemand" => disabled\n'
  fi
  printf '\t}\n'
  ;;
kill)
  ;;
disable)
  printf 'disabled\n' >"$FAKE_GATE"
  ;;
enable)
  printf 'enabled\n' >"$FAKE_GATE"
  ;;
bootout)
  if [ "$(_gate)" = "disabled" ]; then printf 'absent\n' >"$FAKE_STATE"; fi
  ;;
bootstrap)
  # The disabled gate is a load-time gate, so a closed gate blocks the bootstrap.
  if [ "$(_gate)" = "disabled" ]; then
    printf 'Bootstrap failed: 5: Input/output error\n' >&2
    exit 5
  fi
  printf 'loaded\n' >"$FAKE_STATE"
  ;;
start)
  printf 'loaded\n' >"$FAKE_STATE"
  ;;
esac
exit 0
FAKE_LAUNCHCTL
cat >"$_tmp/bin/sw_vers" <<'FAKE_SW_VERS'
#!/usr/bin/env bash
printf '27.0\n'
FAKE_SW_VERS
cat >"$_tmp/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/sw_vers" "$_tmp/bin/sleep"

# run_svc <args...>: the real CLI against the stub registry and the fake manager.
run_svc() { # <svc.sh args...>
  env NUCLEUS_HOST=MacBook \
    NUCLEUS_REPO_ROOT="$_tmp/repo" \
    HOME="$_tmp/home" \
    NUCLEUS_LOG_DIR="$_tmp/log" \
    SUDO_USER="svc-test-nomounts" \
    PATH="$_tmp/bin:$PATH" \
    bash "$SVC_SH" "$@"
}

cli_output=""
cli_status=0
# run_cli: a fresh job/gate/log per case; captures combined output and status.
run_cli() { # <svc.sh args...>
  local job_state="${CLI_JOB_STATE:-absent}" gate_state="${CLI_GATE_STATE:-enabled}"
  printf '%s\n' "$job_state" >"$FAKE_STATE"
  printf '%s\n' "$gate_state" >"$FAKE_GATE"
  : >"$FAKE_LOG"
  unset CLI_JOB_STATE CLI_GATE_STATE
  cli_status=0
  cli_output="$(run_svc "$@" 2>&1)" || cli_status=$?
}

# calls: the recorded verbs in order, one space-separated line.
calls() {
  awk '{ printf "%s ", $1 }' "$FAKE_LOG"
}

# count_call <verb>: how many times that verb was recorded.
count_call() {
  awk -v v="$1" '$1 == v { n++ } END { print n + 0 }' "$FAKE_LOG"
}

# before <earlier> <later>: true when the earlier verb was recorded first.
before() {
  awk -v a="$1" -v b="$2" '
    $1 == a && !x { x = NR }
    $1 == b && !y { y = NR }
    END { exit ((x && y && x < y) ? 0 : 1) }
  ' "$FAKE_LOG"
}

CLI_JOB_STATE=loaded
run_cli stop demo
assert_eq "0" "$cli_status" "stop exits 0"
if contains "$cli_output" "--disable"; then
  assert_pass "stop warns through the CLI and names --disable"
else
  assert_fail "stop warns through the CLI and names --disable" "$cli_output"
fi
assert_eq "1" "$(count_call kill)" "the warned stop still sends its signal"

CLI_JOB_STATE=loaded
run_cli stop demo-ondemand
assert_eq "0" "$cli_status" "an onDemand stop exits 0"
if contains "$cli_output" "--disable"; then
  assert_fail "an onDemand stop is silent" "$cli_output"
else
  assert_pass "an onDemand stop is silent"
fi

for _order in "stop demo --disable" "stop --disable demo"; do
  CLI_JOB_STATE=loaded
  # shellcheck disable=SC2086 # reason: the case supplies the argument order under test
  run_cli $_order
  assert_eq "0" "$cli_status" "'$_order' exits 0"
  if contains "$cli_output" "--disable"; then
    assert_fail "'$_order' does not warn about the remedy it applies" "$cli_output"
  else
    assert_pass "'$_order' does not warn about the remedy it applies"
  fi
  if before kill disable && before disable bootout; then
    assert_pass "'$_order' stops before it disables, and disables before it unloads"
  else
    assert_fail "'$_order' stops before it disables, and disables before it unloads" "calls=$(calls)"
  fi
done

CLI_JOB_STATE=absent CLI_GATE_STATE=disabled
run_cli start --enable demo
assert_eq "0" "$cli_status" "'start --enable demo' exits 0"
if before enable bootstrap; then
  assert_pass "start --enable enables before it starts"
else
  assert_fail "start --enable enables before it starts" "calls=$(calls)"
fi
if contains "$cli_output" "--enable"; then
  assert_fail "start --enable does not warn about the remedy it applies" "$cli_output"
else
  assert_pass "start --enable does not warn about the remedy it applies"
fi

CLI_JOB_STATE=absent CLI_GATE_STATE=disabled
run_cli start demo
assert_eq "1" "$cli_status" "a plain start of a disabled service fails, because the gate blocks the bootstrap"
if contains "$cli_output" "--enable"; then
  assert_pass "a plain start of a disabled service warns and names --enable"
else
  assert_fail "a plain start of a disabled service warns and names --enable" "$cli_output"
fi

CLI_JOB_STATE=absent
run_cli stop --enable demo
assert_eq "1" "$cli_status" "stop --enable is rejected"
if contains "$cli_output" "--enable" && contains "$cli_output" "start"; then
  assert_pass "the rejection names the flag and the action it belongs to"
else
  assert_fail "the rejection names the flag and the action it belongs to" "$cli_output"
fi
assert_eq "0" "$(count_call kill)" "a rejected stop performs no action"
assert_eq "" "$(calls)" "a rejected stop calls no service manager"

CLI_JOB_STATE=absent
run_cli start --disable demo
assert_eq "1" "$cli_status" "start --disable is rejected"
if contains "$cli_output" "--disable" && contains "$cli_output" "stop"; then
  assert_pass "the rejection names the disable flag and stop"
else
  assert_fail "the rejection names the disable flag and stop" "$cli_output"
fi
assert_eq "0" "$(count_call bootstrap)" "a rejected start performs no action"

finish_tests
