#!/usr/bin/env bash
# Tests for launchctl_service_enabled in
# src/scripts/lib/macos-launch-services.sh and for the macOS branch of
# svc_status in scripts/svc.sh: the disabled gate that `launchctl enable` and
# `launchctl disable` write. `launchctl list` shows loaded-ness, so a status
# derived from it cannot see the gate at all, which is why `nucleus-svc enable`
# and `disable` looked inert. The assertions describe the contract: two exact
# override lines are read, every other shape including a failed command is
# unknown, and status keeps that verdict tri-state.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state
# shellcheck source=../../src/scripts/lib/macos-launch-services.sh
. "$SCRIPT_DIR/../../src/scripts/lib/macos-launch-services.sh"
# svc_status ends with the shared health-marker epilogue, so the suite sources it
# instead of shadowing it.
# shellcheck source=../../src/scripts/lib/service-health.sh
. "$SCRIPT_DIR/../../src/scripts/lib/service-health.sh"

require_command jq "the status projection reads the JSON svc_status emits"

SVC_SH="$REPO_ROOT/scripts/svc.sh"
# svc_status runs as root against the console user's session; the suite is not
# root, but the name stays defined so the branch cannot trip `set -u`.
# shellcheck disable=SC2034 # reason: read by the extracted svc_status body, not by this file
REAL_USER_UID="$(id -u)"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"

FAKE_LOG="$_tmp/launchctl.log"
FAKE_BODY="$_tmp/print-disabled.body"
FAKE_RC="$_tmp/print-disabled.rc"
# FAKE_LOADED: the labels the fake reports as loaded, so the status assertions
# can tell a running job from an unloaded one.
FAKE_LOADED=""
export FAKE_LOG FAKE_BODY FAKE_RC FAKE_LOADED

# --- Fake service manager -----------------------------------------------------
# Models only what the code under test reads: a print-disabled reply and its exit
# status from files, so a well-formed reply and a broken read are both reachable,
# plus list and print for the loaded-ness svc_status still derives from them. The
# sudo stub logs and executes, which is how the sudo prefix a system-scope probe
# passes stays observable.
cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "${1:-}" in
print-disabled)
  cat "$FAKE_BODY"
  exit "$(cat "$FAKE_RC")"
  ;;
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LOADED:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  for _label in ${FAKE_LOADED:-}; do
    case "${*: -1}" in
    */"$_label")
      printf 'state = running\n\tpid = 4242\n'
      exit 0
      ;;
    esac
  done
  printf 'Could not find service\n' >&2
  exit 113
  ;;
esac
exit 0
FAKE_LAUNCHCTL
cat >"$_tmp/bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$FAKE_LOG"
exec "$@"
FAKE_SUDO
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/sudo"
PATH="$_tmp/bin:$PATH"
export PATH

_DOMAIN="gui/501"

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

# override_map <entry...>: the reply shape `launchctl print-disabled` emits, one
# `"<label>" => enabled|disabled` line per overridden label, including the blank
# lead line and the tab indentation of the real command.
override_map() { # <entry...>
  local out=$'\n\tdisabled services = {\n' entry
  for entry in "$@"; do
    out+="$(printf '\t\t%s\n' "$entry")"
  done
  printf '%s\t}\n' "$out"
}

# serve <exit status> [entry...]: a fresh reply and an empty call log.
serve() { # <rc> [entry...]
  local rc="$1"
  shift
  if [ "$#" -gt 0 ]; then
    override_map "$@" >"$FAKE_BODY"
  else
    : >"$FAKE_BODY"
  fi
  printf '%s\n' "$rc" >"$FAKE_RC"
  : >"$FAKE_LOG"
}

# probe_rc <domain-target> <label> <sudo-prefix>: "rc=<status> out=<verdict>", so
# the always-zero return contract is asserted alongside each verdict.
probe_rc() { # <domain-target> <label> <sudo-prefix>
  local _out _rc=0
  _out=$(launchctl_service_enabled "$@") || _rc=$?
  printf 'rc=%s out=%s' "$_rc" "$_out"
}

section 1 "Verdict from the overrides database"

serve 0 '"local.demo" => disabled' '"local.other" => enabled'
assert_eq "disabled" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "a label the overrides database marks disabled reports disabled"

serve 0 '"local.demo" => enabled' '"local.other" => disabled'
assert_eq "enabled" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "a label the overrides database marks enabled reports enabled"

serve 0 '"local.other" => disabled' '"local.third" => enabled'
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.absent '')" \
  "a label missing from the overrides database reports unknown, not enabled"

serve 0 '"local.demo-extra" => disabled'
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "a longer label that starts the same way is not a match"

serve 0 '"local.demo" => disabled'
assert_eq "rc=0 out=disabled" "$(probe_rc "$_DOMAIN" local.demo '')" \
  "a disabled verdict returns 0"

serve 0 '"local.demo" => enabled'
assert_eq "rc=0 out=enabled" "$(probe_rc "$_DOMAIN" local.demo '')" \
  "an enabled verdict returns 0"

serve 0 '"local.other" => enabled'
assert_eq "rc=0 out=unknown" "$(probe_rc "$_DOMAIN" local.demo '')" \
  "an unknown verdict returns 0"

section 2 "A read that cannot be trusted is unknown, never enabled"

serve 1 '"local.demo" => disabled'
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "a failing launchctl reports unknown even when its output claims disabled"

serve 2 '"local.demo" => enabled'
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "a failing launchctl reports unknown even when its output claims enabled"

serve 0
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "an empty reply reports unknown"

serve 0 'state = running' 'pid = 4242'
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "a reply without the overrides map reports unknown"

serve 0 'local.demo => disabled'
assert_eq "unknown" "$(launchctl_service_enabled "$_DOMAIN" local.demo '')" \
  "an unquoted line is not one of the two shapes the probe reads"

section 3 "The probe addresses the domain target with the caller's sudo prefix"

serve 0 '"local.demo" => enabled'
_rc=0
launchctl_service_enabled "$_DOMAIN" local.demo '' >/dev/null || _rc=$?
assert_eq "print-disabled gui/501" "$(cat "$FAKE_LOG")" \
  "a gui probe reads the gui domain target"
assert_eq "0" "$_rc" "a gui probe returns 0"

serve 0 '"local.demo" => enabled'
_rc=0
launchctl_service_enabled system local.demo sudo >/dev/null || _rc=$?
if [ "$_rc" -eq 0 ] && contains "$(cat "$FAKE_LOG")" "sudo launchctl print-disabled system"; then
  assert_pass "a system probe reads the system domain target through the sudo prefix"
else
  assert_fail "a system probe reads the system domain target through the sudo prefix" \
    "rc=$_rc log=[$(tr '\n' ';' <"$FAKE_LOG")]"
fi

section 4 "status reports the gate, not loaded-ness"

# svc_status is exercised as the script defines it: sourcing scripts/svc.sh would
# run the CLI, and the defect this section guards is in that function's body.
STATUS_FUNC="$(extract_func svc_status "$SVC_SH")"
if [ -z "$STATUS_FUNC" ]; then
  assert_fail "the status function is defined in scripts/svc.sh" \
    "extract_func svc_status returned nothing from $SVC_SH"
  finish_tests
fi
eval "$STATUS_FUNC"

status_entry='{"type":"macos-launchctl","service":"local.demo","scope":"user","launchdDomain":"gui"}'

# status_field <field> <entry_json>: one svc_status call projected to one field.
# A non-zero status is printed as the projection, so the assertion reports the
# failure instead of aborting the suite before the tally.
status_field() { # <field> <entry_json>
  local _out _rc=0
  _out=$(svc_status demo "$2") || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'status failed rc=%s' "$_rc"
    return 0
  fi
  printf '%s' "$_out" | jq -r "$1"
}

FAKE_LOADED=local.demo
serve 0 '"local.demo" => disabled'
assert_eq "false" "$(status_field .enabled "$status_entry")" \
  "a running job with the gate disabled reports enabled=false"
assert_eq "true" "$(status_field .running "$status_entry")" \
  "the disabled gate leaves running untouched"
assert_eq "active" "$(status_field .status "$status_entry")" \
  "the disabled gate leaves status untouched"

serve 0 '"local.demo" => enabled'
assert_eq "true" "$(status_field .enabled "$status_entry")" \
  "a gate the database marks enabled reports enabled=true"

serve 0 '"local.other" => enabled'
assert_eq "null" "$(status_field .enabled "$status_entry")" \
  "a label missing from the database reports enabled=null"

serve 1 '"local.demo" => disabled'
assert_eq "null" "$(status_field .enabled "$status_entry")" \
  "an unreadable database reports enabled=null, not disabled"

FAKE_LOADED=""
serve 0 '"local.demo" => disabled'
assert_eq "false" "$(status_field .running "$status_entry")" \
  "an unloaded job is still reported as not running"
assert_eq "false" "$(status_field .enabled "$status_entry")" \
  "an unloaded and disabled job reports enabled=false"

serve 0 '"local.demo" => enabled'
assert_eq "true" "$(status_field .enabled "$status_entry")" \
  "an unloaded job leaves the enabled verdict to the database"

finish_tests
