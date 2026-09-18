#!/usr/bin/env bash
# End-to-end resolution tests for scripts/svc.sh — a prefix-match registry entry
# must resolve to concrete instance ids that list, status, actions, and verify
# all agree on.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "svc resolution tests build a stub registry with jq"

SVC_SH="$SCRIPT_DIR/../../scripts/svc.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/repo/src/modules" "$_tmp/bin" "$_tmp/home" "$_tmp/log"

# --- Stub registry -----------------------------------------------------------
# One prefix-match entry with two host shapes plus one ordinary entry, so the
# assertions describe resolution behaviour without depending on the real
# registry's contents.
cat >"$_tmp/repo/src/modules/services.json" <<'JSON'
{
  "cloud-drive": {
    "displayName": "Cloud Drive Mounts",
    "hosts": {
      "MacBook": {
        "type": "launchctl",
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
      "MacBook": { "type": "launchctl", "service": "local.plain", "scope": "user" }
    }
  }
}
JSON

# --- Fake launchctl ----------------------------------------------------------
# FAKE_LIVE lists the labels the fake reports as loaded; every mutating
# subcommand is appended to FAKE_LAUNCHCTL_LOG so tests can assert exactly which
# targets an action touched.
cat >"$_tmp/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LIVE:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  for _label in ${FAKE_LIVE:-}; do
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
kill | enable | disable | bootout | bootstrap | start | kickstart)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  ;;
*)
  exit 1
  ;;
esac
FAKE
chmod +x "$_tmp/bin/launchctl"

# run_svc — Run the CLI against the stub registry with the fake manager on PATH.
run_svc() { # <svc.sh args...>
  env NUCLEUS_HOST=MacBook \
    NUCLEUS_REPO_ROOT="$_tmp/repo" \
    HOME="$_tmp/home" \
    NUCLEUS_LOG_DIR="$_tmp/log" \
    PATH="$_tmp/bin:$PATH" \
    FAKE_LIVE="${FAKE_LIVE:-}" \
    FAKE_LAUNCHCTL_LOG="$_tmp/launchctl.log" \
    bash "$SVC_SH" "$@"
}

# assert_eq — Compare an actual value with the expected one.
assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# assert_contains — Assert a captured output block contains a substring.
assert_contains() { # <test name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1" ;;
  *) assert_fail "$1" "expected output to contain '$3', got: $2" ;;
  esac
}

# assert_not_contains — Assert a captured output block lacks a substring.
assert_not_contains() { # <test name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_fail "$1" "expected output not to contain '$3', got: $2" ;;
  *) assert_pass "$1" ;;
  esac
}

# captured_output / captured_status — Results of the last run_cli call.
captured_output=""
captured_status=0
# run_cli — Run the CLI, capturing combined output and exit status.
run_cli() { # <svc.sh args...>
  captured_status=0
  captured_output="$(run_svc "$@" 2>&1)" || captured_status=$?
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
assert_eq "aggregate action touches every live instance" 2 "$(wc -l <"$_tmp/launchctl.log" | tr -d ' ')"
assert_contains "aggregate action covers the first instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.iCloud"
assert_contains "aggregate action covers the second instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.OneDrive"

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

finish_tests
