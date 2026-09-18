#!/usr/bin/env bash
# Tests for src/scripts/lib/svc-instances.sh — instance id derivation, anchored
# live enumeration, per-instance log directories, and not-loaded markers.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/svc-instances.sh
. "$SCRIPT_DIR/../../src/scripts/lib/svc-instances.sh"

require_command jq "svc-instances tests parse registry JSON with jq"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"

# --- Fake service managers ---------------------------------------------------
# The library enumerates live instances through the platform manager, so the
# fakes emit fixed lists: assertions then describe the resolution contract, not
# whatever happens to be running on the test machine.
cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LIVE:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
*)
  exit 1
  ;;
esac
FAKE_LAUNCHCTL
cat >"$_tmp/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
for _arg in "$@"; do
  if [ "$_arg" = "list-units" ]; then
    for _unit in ${FAKE_UNITS:-}; do printf '%s loaded active running fake\n' "$_unit"; done
    exit 0
  fi
done
exit 1
FAKE_SYSTEMCTL
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/systemctl"
PATH="$_tmp/bin:$PATH"
export PATH

LAUNCHCTL_ENTRY='{"type":"launchctl","service":"local.cloud-mount.","scope":"user","launchdDomain":"gui","prefixMatch":true}'
SYSTEMCTL_ENTRY='{"type":"systemctl","service":"cloud-mount-","scope":"user","prefixMatch":true}'
SCHTASK_ENTRY='{"type":"schtask","service":"NucleusCloudMount-","taskPath":"\\NucleusCloudMount","prefixMatch":true}'

# assert_eq — Compare an actual value with the expected one.
assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

section 1 "Instance id derivation"
assert_eq "launchd label maps to the mount suffix" "iCloud" \
  "$(svc_instance_suffix "$LAUNCHCTL_ENTRY" 'local.cloud-mount.iCloud')"
assert_eq "systemd unit maps to the mount suffix" "iCloud" \
  "$(svc_instance_suffix "$SYSTEMCTL_ENTRY" 'cloud-mount-iCloud.service')"
assert_eq "scheduled-task path maps to the mount suffix" "iCloud" \
  "$(svc_instance_suffix "$SCHTASK_ENTRY" '\NucleusCloudMount\NucleusCloudMount-iCloud')"
assert_eq "a unit id without the declared prefix keeps only its base name" "other" \
  "$(svc_instance_suffix "$SYSTEMCTL_ENTRY" 'other.service')"

section 2 "Concrete entry synthesis"
assert_eq "launchctl instance entry carries the concrete service id" \
  "gui local.cloud-mount.iCloud" \
  "$(svc_instance_entry "$LAUNCHCTL_ENTRY" 'local.cloud-mount.iCloud' | jq -r '[.launchdDomain, .service] | join(" ")')"
assert_eq "instance entry drops prefixMatch" "false" \
  "$(svc_instance_entry "$LAUNCHCTL_ENTRY" 'local.cloud-mount.iCloud' | jq -r 'has("prefixMatch")')"
assert_eq "schtask instance entry carries the concrete task path" \
  '\NucleusCloudMount\NucleusCloudMount-iCloud' \
  "$(svc_instance_entry "$SCHTASK_ENTRY" '\NucleusCloudMount\NucleusCloudMount-iCloud' | jq -r '.taskPath')"

section 3 "Live enumeration"
FAKE_LIVE="local.cloud-mount.a xlocal.cloud-mount.b local.cloud-mount.c unrelated"
export FAKE_LIVE
assert_eq "launchctl instances match the literal prefix only" "local.cloud-mount.a
local.cloud-mount.c" "$(svc_prefix_instances "$LAUNCHCTL_ENTRY")"

FAKE_LIVE=""
export FAKE_LIVE
assert_eq "no live instance yields empty output" "" "$(svc_prefix_instances "$LAUNCHCTL_ENTRY")"
if svc_prefix_instances "$LAUNCHCTL_ENTRY" >/dev/null; then
  assert_pass "no live instance still exits 0"
else
  assert_fail "no live instance still exits 0" "enumeration failed on an empty result"
fi

FAKE_UNITS="cloud-mount-b.service xcloud-mount-c.service"
export FAKE_UNITS
assert_eq "systemd units match the literal prefix only" "cloud-mount-b.service" \
  "$(svc_prefix_instances "$SYSTEMCTL_ENTRY")"
FAKE_UNITS=""
export FAKE_UNITS
assert_eq "an entry with no service prefix enumerates nothing" "" \
  "$(svc_prefix_instances '{"type":"launchctl","scope":"user"}')"

section 4 "Per-instance log directories"
assert_eq "user instance dir expands the <instance> token" "$_tmp/log/cloud-mount-iCloud" \
  "$(svc_instance_log_dirs '{"service":"cloud-mount-","logging":{"instanceDirs":{"user":["cloud-mount-<instance>"]}}}' "$_tmp/log" "$_tmp/syslog" 'cloud-mount-iCloud.service')"
assert_eq "system instance dir uses the system log root" "$_tmp/syslog/cloud-mount-iCloud" \
  "$(svc_instance_log_dirs '{"service":"cloud-mount-","logging":{"instanceDirs":{"system":["cloud-mount-<instance>"]}}}' "$_tmp/log" "$_tmp/syslog" 'cloud-mount-iCloud.service')"
assert_eq "an entry without instanceDirs yields no directories" "" \
  "$(svc_instance_log_dirs "$LAUNCHCTL_ENTRY" "$_tmp/log" "$_tmp/syslog" 'local.cloud-mount.iCloud')"

section 5 "Not-loaded transition markers"
assert_eq "the first report of a not-loaded instance is a transition" "first" \
  "$(svc_notloaded_transition cloud-drive "$_tmp/state")"
assert_eq "a repeated report is not a transition" "repeat" \
  "$(svc_notloaded_transition cloud-drive "$_tmp/state")"
svc_notloaded_clear cloud-drive "$_tmp/state"
assert_eq "clearing the marker restores the transition" "first" \
  "$(svc_notloaded_transition cloud-drive "$_tmp/state")"
svc_notloaded_transition other "$_tmp/state" >/dev/null
assert_eq "markers are per key" "repeat" "$(svc_notloaded_transition other "$_tmp/state")"

finish_tests
