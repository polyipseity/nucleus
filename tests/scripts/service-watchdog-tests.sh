#!/usr/bin/env bash
# Tests for src/scripts/services/service-watchdog.sh — a prefix-match registry
# entry must be watched per instance, and an instance the user registry declares
# but this host does not run must be reported once per transition, never loaded.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "service watchdog tests build a stub registry with jq"

WATCHDOG="$REPO_ROOT/src/scripts/services/service-watchdog.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/repo/src/modules" "$_tmp/bin" "$_tmp/home"
# Discovery reads the user registry through the live repository root, so the
# stub tree points at the shared fixture instead of any real user's data.
ln -s "$REPO_ROOT/tests/fixtures/user-registry/src/users" "$_tmp/repo/src/users"

cat >"$_tmp/repo/src/modules/services.json" <<JSON
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
      },
      "NixOS": {
        "type": "systemctl",
        "prefixMatch": true,
        "service": "cloud-mount-",
        "scope": "user"
      }
    }
  }
}
JSON

# --- Fake launchctl ----------------------------------------------------------
# FAKE_LIVE lists loaded labels, FAKE_STATE simulates the `print` state. Every
# mutating subcommand is appended to FAKE_LAUNCHCTL_LOG so assertions can prove
# exactly which instance was recovered (or that none was touched).
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
      printf 'state = %s\n\tpid = 4242\n' "${FAKE_STATE:-running}"
      exit 0
      ;;
    esac
  done
  printf 'Service is not found\n'
  exit 1
  ;;
bootout | bootstrap | kickstart | enable | disable | kill)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  ;;
*)
  exit 1
  ;;
esac
FAKE

# --- Fake systemctl ----------------------------------------------------------
# FAKE_UNITS lists units the fake reports as loaded, FAKE_SYSTEMCTL_STATE the
# is-active answer; restarts are recorded for assertion.
cat >"$_tmp/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
*" list-units "*)
  for _unit in ${FAKE_UNITS:-}; do printf '%s loaded active running fake\n' "$_unit"; done
  exit 0
  ;;
*" is-active "*)
  printf '%s\n' "${FAKE_SYSTEMCTL_STATE:-active}"
  exit 0
  ;;
*" is-enabled "*)
  printf 'enabled\n'
  exit 0
  ;;
*" reset-failed "* | *" restart "*)
  printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
  exit 0
  ;;
esac
exit 1
FAKE

chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/systemctl"

# run_watchdog — Run one watchdog iteration against the stub host.
run_watchdog() {
  env NUCLEUS_HOST="${WATCHDOG_TEST_HOST:-MacBook}" \
    NUCLEUS_REPO_ROOT="$_tmp/repo" \
    NUCLEUS_SERVICES_JSON="$_tmp/repo/src/modules/services.json" \
    HOME="$_tmp/home" \
    SUDO_USER="${SUDO_USER_OVERRIDE:-svc-test-nomounts}" \
    PATH="$_tmp/bin:$PATH" \
    FAKE_LIVE="${FAKE_LIVE:-}" \
    FAKE_UNITS="${FAKE_UNITS:-}" \
    FAKE_STATE="${FAKE_STATE:-running}" \
    FAKE_SYSTEMCTL_STATE="${FAKE_SYSTEMCTL_STATE:-active}" \
    FAKE_LAUNCHCTL_LOG="$_tmp/launchctl.log" \
    FAKE_SYSTEMCTL_LOG="$_tmp/systemctl.log" \
    bash "$WATCHDOG" --oneshot
}

# state_dir — Where the watchdog keeps crash-loop and transition markers.
state_dir="$_tmp/home/Library/Application Support/nucleus/state/service-stats"

# captured_output / captured_status — Results of the last run_watchdog call.
captured_output=""
captured_status=0
run_capture() {
  captured_status=0
  captured_output="$(run_watchdog 2>&1)" || captured_status=$?
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

# assert_eq — Compare an actual value with the expected one.
assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

# calls_made — Number of mutating manager calls recorded since the last reset.
calls_made() {
  local file="$1"
  if [ -f "$file" ]; then wc -l <"$file" | tr -d ' '; else printf '0'; fi
}

section 1 "Healthy instances are left alone"
FAKE_LIVE="local.cloud-mount.iCloud"
: >"$_tmp/launchctl.log"
run_capture
assert_eq "a healthy instance exits 0" 0 "$captured_status"
assert_eq "a healthy instance is not touched" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "a healthy instance prints nothing" "" "$captured_output"

section 2 "A stuck instance is recovered"
FAKE_LIVE="local.cloud-mount.iCloud"
FAKE_STATE="spawn scheduled"
: >"$_tmp/launchctl.log"
run_capture
assert_eq "a stuck instance exits 0" 0 "$captured_status"
assert_contains "the instance is booted out" "$(cat "$_tmp/launchctl.log")" "bootout"
assert_contains "the instance is bootstrapped again" "$(cat "$_tmp/launchctl.log")" "bootstrap"
assert_contains "the recovered target is that instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.iCloud"
assert_contains "the restart is logged" "$captured_output" "restarted local.cloud-mount.iCloud"

section 3 "A crash-looping instance is not restarted"
FAKE_STATE="spawn scheduled"
mkdir -p "$state_dir"
# Seed recent restart timestamps directly: the library records at most one
# restart per second, so building a loop through it would need real elapsed
# time, and the crash-loop window only counts the last hour.
jq -n --argjson now "$(date +%s)" '{restarts: [range($now - 11; $now + 1)], lastSuccess: 0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"
: >"$_tmp/launchctl.log"
run_capture
assert_eq "a crash-looping instance exits 0" 0 "$captured_status"
assert_eq "a crash-looping instance is not touched" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_contains "the crash loop is reported" "$captured_output" "crash-looping"
rm -f "$state_dir/local.cloud-mount.iCloud.json"

section 4 "No instances and nothing configured"
FAKE_LIVE=""
SUDO_USER_OVERRIDE=svc-test-nomounts
: >"$_tmp/launchctl.log"
run_capture
assert_eq "an empty expansion exits 0" 0 "$captured_status"
assert_eq "an empty expansion touches nothing" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "an empty expansion prints nothing" "" "$captured_output"

section 5 "Declared but not loaded instances are reported once"
SUDO_USER_OVERRIDE=test-user
: >"$_tmp/launchctl.log"
run_capture
assert_eq "reporting a declared mount exits 0" 0 "$captured_status"
assert_contains "the declared mount is reported" "$captured_output" "local.cloud-mount.iCloud configured but not loaded"
assert_contains "every declared mount is reported" "$captured_output" "local.cloud-mount.OneDrive configured but not loaded"
assert_contains "the report names a remedy" "$captured_output" "nucleus-apply"
assert_eq "a declared mount is never loaded" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "the declared mount is reported exactly once" 3 \
  "$(printf '%s\n' "$captured_output" | grep -c 'configured but not loaded' || true)"

run_capture
assert_eq "a repeated iteration stays silent" "" "$captured_output"

section 6 "A live instance clears the transition marker"
FAKE_LIVE="local.cloud-mount.iCloud"
run_capture
assert_eq "a returning instance exits 0" 0 "$captured_status"
assert_not_contains "a returning instance is not reported as not loaded" "$captured_output" "local.cloud-mount.iCloud configured"
if [ -e "$state_dir/local.cloud-mount.iCloud.notloaded" ]; then
  assert_fail "the transition marker is cleared" "marker still present"
else
  assert_pass "the transition marker is cleared"
fi

FAKE_LIVE=""
run_capture
assert_contains "a flapping instance is reported again" "$captured_output" "local.cloud-mount.iCloud configured but not loaded"
assert_not_contains "the still-live mounts are not repeated" "$captured_output" "local.cloud-mount.GoogleDrive configured"

section 7 "NixOS units are checked per instance"
WATCHDOG_TEST_HOST=NixOS
FAKE_UNITS="cloud-mount-iCloud.service"
FAKE_SYSTEMCTL_STATE="failed"
FAKE_LIVE=""
: >"$_tmp/systemctl.log"
run_capture
assert_eq "the NixOS run exits 0" 0 "$captured_status"
assert_contains "the user-scope unit is restarted" "$(cat "$_tmp/systemctl.log")" "--user restart cloud-mount-iCloud.service"
assert_contains "the failing instance is logged" "$captured_output" "restarted cloud-mount-iCloud.service"
WATCHDOG_TEST_HOST=
FAKE_SYSTEMCTL_STATE=
FAKE_UNITS=

finish_tests
