#!/usr/bin/env bash
# End-to-end resolution tests for scripts/svc.sh, a prefix-match registry entry
# must resolve to concrete instance ids that list, status, actions, and verify
# all agree on.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "svc resolution tests build a stub registry with jq"

SVC_SH="$SCRIPT_DIR/../../scripts/svc.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/repo/src/modules" "$_tmp/bin" "$_tmp/home" "$_tmp/log"

# The user registry is discovery's source of truth, so the stub repo needs a
# users tree. The default resolving user has no entry there (no mounts); section
# 8 switches to the fixture's test-user, which declares mounts.
ln -s "$REPO_ROOT/tests/fixtures/user-registry/src/users" "$_tmp/repo/src/users"

# --- Stub registry -----------------------------------------------------------
# One prefix-match entry with two host shapes plus one ordinary entry, so the
# assertions describe resolution behaviour without depending on the real
# registry's contents.
cat >"$_tmp/repo/src/modules/services.json" <<JSON
{
  "\$logging": {
    "MacBook": {
      "logDir": "$_tmp/log",
      "systemLogDir": "$_tmp/syslog"
    }
  },
  "cloud-drive": {
    "displayName": "Cloud Drive Mounts",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "prefixMatch": true,
        "service": "local.cloud-mount.",
        "scope": "user",
        "launchdDomain": "gui",
        "logging": { "instanceDirs": { "user": ["cloud-mount-<instance>"] } }
      },
      "NixOS": {
        "type": "nixos-systemctl",
        "prefixMatch": true,
        "service": "cloud-mount-",
        "scope": "user"
      }
    }
  },
  "plain-service": {
    "displayName": "Plain Service",
    "hosts": {
      "MacBook": { "type": "macos-launchctl", "service": "local.plain", "scope": "user" }
    }
  }
}
JSON

# --- Fake launchctl ----------------------------------------------------------
# FAKE_LIVE lists the labels the fake starts out reporting as loaded, and every
# mutating subcommand is appended to FAKE_LAUNCHCTL_LOG so tests can assert
# exactly which targets an action touched. The reported set lives in a file
# because a `bootout` clears a label for the rest of the CLI run, which a single
# process cannot see in its own environment. The disabled gate lives in a second
# file for the same reason: `disable` and `enable` are separate processes.
cat >"$_tmp/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
_gate() { cat "${FAKE_GATE_FILE:?}" 2>/dev/null || printf 'enabled\n'; }
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in $(cat "${FAKE_LOADED:?}" 2>/dev/null); do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  for _label in $(cat "${FAKE_LOADED:?}" 2>/dev/null); do
    case "${2:-}" in
    *"$_label")
      printf 'state = running\n\tpid = 4242\n'
      exit 0
      ;;
    esac
  done
  printf 'state = not running\n\tlast exit code = 0\n'
  exit 1
  ;;
print-disabled)
  printf '\n\tdisabled services = {\n'
  for _label in $(cat "${FAKE_LOADED:?}" 2>/dev/null); do
    printf '\t\t"%s" => %s\n' "$_label" "$(_gate)"
  done
  printf '\t}\n'
  ;;
disable | enable)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  if [ "$1" = "disable" ]; then printf 'disabled' >"${FAKE_GATE_FILE:?}"; else printf 'enabled' >"${FAKE_GATE_FILE:?}"; fi
  ;;
bootout)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  _target="${*: -1}"
  _kept=""
  for _label in $(cat "${FAKE_LOADED:?}" 2>/dev/null); do
    # A KeepAlive job respawns unless the gate is already closed, so an unload
    # that arrives before the gate leaves the label loaded.
    if [ "$(_gate)" = "disabled" ]; then
      case "$_target" in
      *"$_label") continue ;;
      esac
    fi
    _kept="${_kept:+$_kept }$_label"
  done
  printf '%s\n' "$_kept" >"${FAKE_LOADED:?}"
  ;;
kill | bootstrap | start | kickstart)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  ;;
*)
  exit 1
  ;;
esac
FAKE
chmod +x "$_tmp/bin/launchctl"

# The unload poll sleeps between probes; a no-op keeps the bounded poll free.
cat >"$_tmp/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$_tmp/bin/sleep"

# --- Fake systemctl/journalctl (NixOS rows) -------------------------------
# FAKE_UNITS lists the units the fake reports as loaded; journalctl records each
# invocation so tests can assert which unit an instance log request targeted.
cat >"$_tmp/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
for _arg in "$@"; do
  case "$_arg" in
  list-units)
    for _unit in ${FAKE_UNITS:-}; do printf '%s loaded active running fake\n' "$_unit"; done
    exit 0
    ;;
  is-active)
    printf 'active\n'
    exit 0
    ;;
  is-enabled)
    printf 'enabled\n'
    exit 0
    ;;
  show)
    printf 'MainPID=4242\n'
    exit 0
    ;;
  esac
done
exit 1
FAKE
cat >"$_tmp/bin/journalctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_JOURNALCTL_LOG:?}"
printf 'journald line for %s\n' "$*"
FAKE
chmod +x "$_tmp/bin/systemctl" "$_tmp/bin/journalctl"

# The launchd state a CLI run observes: the labels the fake reports as loaded
# and the disabled gate. Both are files because the verbs are separate processes,
# and both are re-seeded per CLI run so each case starts from its own FAKE_LIVE.
_FAKE_LOADED_FILE="$_tmp/launchd.loaded"
_FAKE_GATE_FILE="$_tmp/launchd.gate"

# run_svc: Run the CLI against the stub registry with fake managers on PATH.
run_svc() { # <svc.sh args...>
  env NUCLEUS_HOST="${SVC_TEST_HOST:-MacBook}" \
    NUCLEUS_REPO_ROOT="$_tmp/repo" \
    HOME="$_tmp/home" \
    NUCLEUS_LOG_DIR="$_tmp/log" \
    SUDO_USER="${SUDO_USER_OVERRIDE:-svc-test-nomounts}" \
    PATH="$_tmp/bin:$PATH" \
    FAKE_LIVE="${FAKE_LIVE:-}" \
    FAKE_UNITS="${FAKE_UNITS:-}" \
    FAKE_LOADED="$_FAKE_LOADED_FILE" \
    FAKE_GATE_FILE="$_FAKE_GATE_FILE" \
    FAKE_LAUNCHCTL_LOG="$_tmp/launchctl.log" \
    FAKE_JOURNALCTL_LOG="$_tmp/journalctl.log" \
    bash "$SVC_SH" "$@"
}

# assert_eq: Compare an actual value with the expected one.
assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# assert_contains: Assert a captured output block contains a substring.
assert_contains() { # <test name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1" ;;
  *) assert_fail "$1" "expected output to contain '$3', got: $2" ;;
  esac
}

# assert_not_contains: Assert a captured output block lacks a substring.
assert_not_contains() { # <test name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_fail "$1" "expected output not to contain '$3', got: $2" ;;
  *) assert_pass "$1" ;;
  esac
}

# captured_output / captured_status: Results of the last run_cli call.
captured_output=""
captured_status=0
# run_cli: Run the CLI, capturing combined output and exit status. The launchd
# state is re-seeded here so one case's unload cannot leak into the next.
run_cli() { # <svc.sh args...>
  printf '%s\n' "${FAKE_LIVE:-}" >"$_FAKE_LOADED_FILE"
  printf 'enabled\n' >"$_FAKE_GATE_FILE"
  captured_status=0
  captured_output="$(run_svc "$@" 2>&1)" || captured_status=$?
}

# count_log <verb>: how many recorded invocations of that launchctl verb.
count_log() { # <verb>
  awk -v v="$1" '$1 == v { n++ } END { print n + 0 }' "$_tmp/launchctl.log"
}

# disable_before_bootout <label>: true when the gate write for that target
# precedes its unload, which is the order a KeepAlive job needs. The logged
# target carries its domain prefix, so the label is compared as a suffix.
disable_before_bootout() { # <label>
  awk -v t="$1" '
    function is_target(field) { return substr(field, length(field) - length(t) + 1) == t }
    $1 == "disable" && is_target($NF) && !d { d = NR }
    $1 == "bootout" && is_target($NF) && !b { b = NR }
    END { exit ((d && b && d < b) ? 0 : 1) }
  ' "$_tmp/launchctl.log"
}

section 1 "Live instances"
FAKE_LIVE="local.cloud-mount.iCloud local.cloud-mount.OneDrive"
run_cli list --user
assert_eq "list exits 0 with live instances" 0 "$captured_status"
assert_contains "list prints the first instance id" "$captured_output" "local.cloud-mount.iCloud"
assert_contains "list prints the second instance id" "$captured_output" "local.cloud-mount.OneDrive"
assert_not_contains "list does not fall back to n/a when instances exist" "$captured_output" "n/a"

run_cli status local.cloud-mount.iCloud
assert_eq "status on a printed instance id exits 0" 0 "$captured_status"
assert_contains "status on a printed instance id reports active" "$captured_output" "active"

section 2 "Actions"
: >"$_tmp/launchctl.log"
run_cli stop local.cloud-mount.iCloud
assert_eq "stopping one instance exits 0" 0 "$captured_status"
assert_eq "stopping one instance touches exactly one target" 1 "$(wc -l <"$_tmp/launchctl.log" | tr -d ' ')"
assert_contains "the touched target is that instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.iCloud"

: >"$_tmp/launchctl.log"
run_cli disable cloud-drive
assert_eq "aggregate action exits 0" 0 "$captured_status"
assert_eq "aggregate action writes the gate for every live instance" 2 "$(count_log disable)"
assert_eq "aggregate action unloads every live instance" 2 "$(count_log bootout)"
assert_contains "aggregate action covers the first instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.iCloud"
assert_contains "aggregate action covers the second instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.OneDrive"
for _instance in local.cloud-mount.iCloud local.cloud-mount.OneDrive; do
  if disable_before_bootout "$_instance"; then
    assert_pass "the gate for $_instance is written before its unload"
  else
    assert_fail "the gate for $_instance is written before its unload" \
      "log=[$(tr '\n' ';' <"$_tmp/launchctl.log")]"
  fi
done

section 3 "Zero instances"
FAKE_LIVE=""
run_cli list --user
assert_eq "list exits 0 with no live instance" 0 "$captured_status"
assert_contains "the prefix row reports n/a" "$captured_output" "n/a"
if printf '%s\n' "$captured_output" | grep -q '^cloud-drive .* n/a '; then
  assert_pass "the prefix row is not reported inactive"
else
  assert_fail "the prefix row is not reported inactive" "cloud-drive row is not n/a: $captured_output"
fi

run_cli restart cloud-drive
assert_eq "acting on a prefix key with no instances fails" 1 "$captured_status"
assert_contains "the failure names the prefix" "$captured_output" "no instances found (prefix 'local.cloud-mount.')"

run_cli verify cloud-drive
assert_eq "verify with no instances is not a failure" 0 "$captured_status"
assert_contains "verify reports the empty expansion" "$captured_output" "no instances found"

section 4 "Unknown names"
run_cli status cloud-driv
assert_eq "an unknown service fails" 1 "$captured_status"
assert_contains "the failure names the requested service" "$captured_output" "cloud-driv"
assert_not_contains "the failure does not print the placeholder name" "$captured_output" "unknown —"

run_cli verify cloud-driv
assert_eq "verify fails on an unknown service" 1 "$captured_status"

FAKE_LIVE="local.cloud-mount.iCloud"
run_cli status local.cloud-mount.nope
assert_eq "a mistyped instance id fails" 1 "$captured_status"
assert_contains "the mistyped id is reported as no such instance" "$captured_output" "no such instance"

section 5 "Ordinary entries"
run_cli status plain-service
assert_eq "an ordinary service still resolves" 0 "$captured_status"
assert_contains "an ordinary service reports its state" "$captured_output" "plain-service"

section 6 "Per-instance logs"
FAKE_LIVE="local.cloud-mount.iCloud local.cloud-mount.OneDrive"
mkdir -p "$_tmp/log/cloud-mount-iCloud" "$_tmp/log/cloud-mount-OneDrive"
printf 'icloud line\n' >"$_tmp/log/cloud-mount-iCloud/stdout.log"
printf 'onedrive line\n' >"$_tmp/log/cloud-mount-OneDrive/stdout.log"

run_cli log-paths local.cloud-mount.iCloud
assert_eq "log-paths on an instance id exits 0" 0 "$captured_status"
assert_contains "log-paths resolves that instance's directory" "$captured_output" "$_tmp/log/cloud-mount-iCloud/stdout.log"
assert_not_contains "log-paths does not leak another instance's directory" "$captured_output" "cloud-mount-OneDrive"

run_cli logs local.cloud-mount.iCloud
assert_eq "logs on an instance id exits 0" 0 "$captured_status"
assert_contains "logs prints that instance's content" "$captured_output" "icloud line"
assert_not_contains "logs does not print another instance's content" "$captured_output" "onedrive line"

run_cli log-paths cloud-drive
assert_eq "log-paths on the prefix key exits 0" 0 "$captured_status"
assert_contains "the aggregate covers the first instance" "$captured_output" "cloud-mount-iCloud"
assert_contains "the aggregate covers the second instance" "$captured_output" "cloud-mount-OneDrive"

run_cli logs
assert_eq "the log listing exits 0" 0 "$captured_status"
assert_contains "the log listing shows instance ids" "$captured_output" "local.cloud-mount.iCloud"
assert_not_contains "the log listing does not list a loaded instance as empty" "$captured_output" "local.cloud-mount.iCloud                    capture=all      (no logs yet)"

FAKE_LIVE=""
run_cli log-paths cloud-drive
assert_eq "log-paths with no instances exits 0" 0 "$captured_status"
assert_eq "log-paths with no instances prints no paths" "" "$captured_output"

section 7 "Instance logs on NixOS (journald)"
FAKE_UNITS="cloud-mount-iCloud.service"
SVC_TEST_HOST=NixOS
: >"$_tmp/journalctl.log"
run_cli logs cloud-mount-iCloud.service
assert_eq "logs on a unit id exits 0" 0 "$captured_status"
assert_contains "instance logs come from journald" "$captured_output" "journald line"
assert_contains "the request targets that instance's unit" "$(cat "$_tmp/journalctl.log")" "-u cloud-mount-iCloud.service"

: >"$_tmp/journalctl.log"
run_cli logs cloud-drive
assert_eq "logs on the prefix key exits 0" 0 "$captured_status"
assert_contains "the aggregate request targets the live unit" "$(cat "$_tmp/journalctl.log")" "-u cloud-mount-iCloud.service"

SVC_TEST_HOST=
FAKE_UNITS=""

section 8 "Configured but not loaded mounts"
SUDO_USER_OVERRIDE=test-user
FAKE_LIVE=""
run_cli list --user
assert_eq "list with declared mounts exits 0" 0 "$captured_status"
assert_contains "a declared mount is reported by its instance id" "$captured_output" "local.cloud-mount.iCloud"
assert_contains "a second declared mount is reported" "$captured_output" "local.cloud-mount.OneDrive"
assert_contains "a third declared mount is reported" "$captured_output" "local.cloud-mount.GoogleDrive"
assert_contains "a declared mount reports not-loaded" "$captured_output" "not-loaded"
assert_not_contains "a declared mount is not reported as n/a" "$captured_output" "n/a"

run_cli list --user --json
assert_eq "json listing with declared mounts exits 0" 0 "$captured_status"
assert_contains "json marks the row configured" "$captured_output" '"configured":true'
assert_contains "json reports the not-loaded status" "$captured_output" '"status":"not-loaded"'

run_cli status local.cloud-mount.iCloud
assert_eq "status on a declared mount exits 0" 0 "$captured_status"
assert_contains "status reports the declared mount as not-loaded" "$captured_output" "not-loaded"

run_cli restart local.cloud-mount.iCloud
assert_eq "acting on a named declared mount fails" 1 "$captured_status"
assert_contains "the failure says it is configured but not loaded" "$captured_output" "configured but not loaded"
assert_contains "the failure names a remedy" "$captured_output" "nucleus-apply"

: >"$_tmp/launchctl.log"
run_cli restart cloud-drive
assert_eq "an aggregate action with only declared mounts exits 0" 0 "$captured_status"
assert_contains "the aggregate action warns" "$captured_output" "configured but not loaded"
assert_eq "a declared mount is never loaded by an action" 0 "$(wc -l <"$_tmp/launchctl.log" | tr -d ' ')"

run_cli verify cloud-drive
assert_eq "verify fails while a declared mount is not loaded" 1 "$captured_status"
assert_contains "verify explains the unmet declaration" "$captured_output" "configured but not loaded"

run_cli status local.cloud-mount.NotDeclared
assert_eq "an undeclared instance id still fails" 1 "$captured_status"
assert_contains "an undeclared instance id is reported as no such instance" "$captured_output" "no such instance"

SUDO_USER_OVERRIDE=

finish_tests
