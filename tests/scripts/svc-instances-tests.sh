#!/usr/bin/env bash
# Tests for src/scripts/lib/svc-instances.sh — instance id derivation, anchored
# live enumeration, per-instance log directories, and not-loaded markers.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/svc-instances.sh
. "$REPO_ROOT/src/scripts/lib/svc-instances.sh"

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
_job_state="$(cat "${FAKE_JOB_STATE:-/dev/null}" 2>/dev/null || printf 'stopped\n')"
case "${1:-}" in
list)  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LIVE:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  # The relaunch loop asks whether an attempt is still in flight. A launched
  # cloud-mount agent exits on a refusal, so an attempt is live for exactly one
  # probe; FAKE_JOB_ALWAYS models one that never goes away.
  if [ -n "${FAKE_JOB_ALWAYS:-}" ]; then
    printf 'state = %s\n' "$FAKE_JOB_ALWAYS"
    [ "$FAKE_JOB_ALWAYS" = running ] && printf '\tpid = 4242\n'
    # FAKE_JOB_BULK — padding after the state lines, so a reader that stops at
    # its first match leaves this writer mid-write; that is the real shape of
    # `launchctl print`, whose output does not fit one pipe buffer. The padding
    # is one blocking write from this shell, so the signal reaches the writer
    # the pipeline reports on.
    if [ -n "${FAKE_JOB_BULK:-}" ]; then
      printf 'filler\n%.0s' $(seq 1 "$FAKE_JOB_BULK")
    fi
    exit 0
  fi
  _live="$(cat "${FAKE_ATTEMPT_LIVE:?}" 2>/dev/null)"
  [ -n "$_live" ] || _live=0
  if [ "$_live" -ge 1 ]; then
    printf '0' >"$FAKE_ATTEMPT_LIVE"
    printf 'state = running\n\tpid = 4242\n'
    exit 0
  fi
  printf 'state = not running\n'
  ;;
kickstart)
  _kicks="$(cat "${FAKE_KICK_CALLS:?}" 2>/dev/null)"
  [ -n "$_kicks" ] || _kicks=0
  printf '%s' "$((_kicks + 1))" >"$FAKE_KICK_CALLS"
  printf '1' >"${FAKE_ATTEMPT_LIVE:?}"
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
# --- Fake mount table --------------------------------------------------------
# The mount probes read the table through `mount`, so a fake one makes the
# assertions describe the table contract instead of whatever this host mounts.
#   FAKE_MOUNT_TABLE — the table the probe reports.
#   FAKE_MOUNT_SLOW  — sleep this long first: a probe that outlives its bound,
#                      which is how a hung volume blocks inside the kernel.
#   FAKE_MOUNT_UNTIL — report the table for this many calls, then report
#                      nothing: a volume that finishes unmounting while it is
#                      being waited on.
#   FAKE_MOUNT_AFTER_KICKS — report nothing until the fake launchctl has been
#                      asked to kickstart this many times: a provider that
#                      refuses the first attempts and serves a later one.
cat >"$_tmp/bin/mount" <<'FAKE_MOUNT'
#!/usr/bin/env bash
if [ -n "${FAKE_MOUNT_UNTIL:-}" ]; then
  calls=0
  [ -f "${FAKE_MOUNT_CALLS:?}" ] && calls="$(cat "$FAKE_MOUNT_CALLS")"
  calls=$((calls + 1))
  printf '%s' "$calls" >"$FAKE_MOUNT_CALLS"
  [ "$calls" -gt "$FAKE_MOUNT_UNTIL" ] && exit 0
fi
if [ -n "${FAKE_MOUNT_AFTER_KICKS:-}" ]; then
  kicks="$(cat "${FAKE_KICK_CALLS:?}" 2>/dev/null)"
  [ -n "$kicks" ] || kicks=0
  [ "$kicks" -lt "$FAKE_MOUNT_AFTER_KICKS" ] && exit 0
fi
[ -n "${FAKE_MOUNT_SLOW:-}" ] && sleep "$FAKE_MOUNT_SLOW"
printf '%s\n' "${FAKE_MOUNT_TABLE:-}"
FAKE_MOUNT
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/systemctl" "$_tmp/bin/mount"
PATH="$_tmp/bin:$PATH"
export PATH
FAKE_MOUNT_TABLE=""
FAKE_MOUNT_SLOW=""
FAKE_MOUNT_UNTIL=""
FAKE_MOUNT_AFTER_KICKS=""
FAKE_MOUNT_CALLS="$_tmp/mount.calls"
FAKE_JOB_STATE="$_tmp/job.state"
FAKE_JOB_ALWAYS=""
FAKE_JOB_BULK=""
FAKE_ATTEMPT_LIVE="$_tmp/attempt.live"
FAKE_KICK_CALLS="$_tmp/kick.calls"
export FAKE_MOUNT_TABLE FAKE_MOUNT_SLOW FAKE_MOUNT_UNTIL FAKE_MOUNT_AFTER_KICKS FAKE_MOUNT_CALLS
export FAKE_JOB_STATE FAKE_JOB_ALWAYS FAKE_JOB_BULK FAKE_ATTEMPT_LIVE FAKE_KICK_CALLS

LAUNCHCTL_ENTRY='{"type": "macos-launchctl","service":"local.cloud-mount.","scope":"user","launchdDomain":"gui","prefixMatch":true}'
SYSTEMCTL_ENTRY='{"type": "nixos-systemctl","service":"cloud-mount-","scope":"user","prefixMatch":true}'
SCHTASK_ENTRY='{"type": "windows-schtask","service":"NucleusCloudMount-","taskPath":"\\NucleusCloudMount","prefixMatch":true}'

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
  "$(svc_prefix_instances '{"type": "macos-launchctl","scope":"user"}')"

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

section 6 "Cloud mount points"

# WHY: the loader hands this function resolved local paths (a host-keyed variant
# is not a mount point yet), so the array mixes both shapes deliberately.
MOUNTS_JSON='[
  {"id":"iCloud","localPath":"clouds/iCloud","remoteName":"iCloud"},
  {"id":"OneDrive","localPath":"clouds/OneDrive","remoteName":"OneDrive"},
  {"id":"NoPath","remoteName":"NoPath"},
  {"id":"HostKeyed","localPath":{"MacBook":"clouds/HostKeyed"},"remoteName":"HostKeyed"}
]'
assert_eq "a declared mount resolves to its home-relative path" "/home/u/clouds/iCloud" \
  "$(svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.iCloud' '/home/u')"
assert_eq "the mount id is the instance suffix, not the instance id" "/home/u/clouds/OneDrive" \
  "$(svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.OneDrive' '/home/u')"
assert_eq "a trailing slash in the home does not double up" "/home/u/clouds/iCloud" \
  "$(svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.iCloud' '/home/u/')"
# mount_point_with_home <home> — The mount point with the base taken from HOME
# instead of the optional argument.
mount_point_with_home() { # <home>
  HOME="$1" svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.iCloud'
}

assert_eq "the home argument is optional" "/h/clouds/iCloud" "$(mount_point_with_home /h)"
assert_eq "an undeclared mount has no mount point" "" \
  "$(svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.Nope' '/home/u')"
assert_eq "a service outside the declared prefix has no mount point" "" \
  "$(svc_cloud_mount_point '{"type":"macos-launchctl","service":"local.plain","scope":"user"}' "$MOUNTS_JSON" 'local.plain' '/home/u')"
assert_eq "a mount without a local path has no mount point" "" \
  "$(svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.NoPath' '/home/u')"
assert_eq "an unresolved host-keyed local path is not a mount point" "" \
  "$(svc_cloud_mount_point "$LAUNCHCTL_ENTRY" "$MOUNTS_JSON" 'local.cloud-mount.HostKeyed' '/home/u')"
assert_eq "an empty home yields no mount point" "" "$(mount_point_with_home '')"
assert_eq "a systemd instance resolves through the same mounts array" "/home/u/clouds/OneDrive" \
  "$(svc_cloud_mount_point "$SYSTEMCTL_ENTRY" "$MOUNTS_JSON" 'cloud-mount-OneDrive.service' '/home/u')"

section 7 "Bounded command probes"

# bounded_rc — Exit status of a command run under svc_run_bounded.
bounded_rc() { # <seconds> <command...>
  local _rc=0
  svc_run_bounded "$@" || _rc=$?
  printf '%s' "$_rc"
}

assert_eq "a successful command keeps its status" "0" "$(bounded_rc 5 true)"
assert_eq "a failing command keeps its status" "1" "$(bounded_rc 5 false)"
assert_eq "a command that outlives its bound reports 124" "124" "$(bounded_rc 1 sleep 5)"
rm -f "$_tmp/bounded.marker"
assert_eq "a command killed at its bound reports 124" "124" \
  "$(bounded_rc 1 sh -c "sleep 5; : > '$_tmp/bounded.marker'")"
if [ -e "$_tmp/bounded.marker" ]; then
  assert_fail "bounded-command-is-stopped" "the command kept running after its bound elapsed"
else
  assert_pass "a command stopped at its bound never finishes its work"
fi

section 8 "Mount table probe"

# mount_table_rc <path> [probe bound] — probe status with the fake table the
# caller set.
mount_table_rc() { # <path> [bound]
  local _rc=0
  svc_mount_table_contains "$1" "${2:-10}" || _rc=$?
  printf '%s' "$_rc"
}

FAKE_MOUNT_TABLE='fake://vol on /mnt/yes (fake, nodev)'
assert_eq "a listed path is reported as mounted" "0" "$(mount_table_rc /mnt/yes)"
assert_eq "an absent path is reported as not mounted" "1" "$(mount_table_rc /mnt/no)"
assert_eq "a path that is a prefix of a listed one is not mounted" "1" "$(mount_table_rc /mnt/y)"
FAKE_MOUNT_TABLE='fake://vol on /mnt/yesmore (fake, nodev)'
assert_eq "a listed path that extends the probe is not a match" "1" "$(mount_table_rc /mnt/yes)"
FAKE_MOUNT_TABLE=''
FAKE_MOUNT_SLOW=''
_mount_out=""
_mount_rc=0
_mount_out="$(svc_mount_table_contains /mnt/any 2>&1)" || _mount_rc=$?
# WHY: an unreadable table is reported, but the return value still says
# "not mounted" — that is the fail-open path the function documents as unsafe.
assert_eq "an unreadable mount table is reported as not mounted" "1" "$_mount_rc"
assert_mentions() { # <slug> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1" ;;
  *) assert_fail "$1" "expected output to mention '$3', got: $2" ;;
  esac
}
assert_mentions "an unreadable mount table is reported" "$_mount_out" "could not read the mount table"

# WHY: a probe that outlives its bound models a hung volume, which must never be
# read as "free" or the next mount lands on top of it.
FAKE_MOUNT_TABLE='fake://vol on /mnt/yes (fake)'
FAKE_MOUNT_SLOW=5
assert_eq "a probe that outlives its bound counts as mounted" "0" "$(mount_table_rc /mnt/yes 1)"
FAKE_MOUNT_SLOW=''

# WHY: the wait is what a reload uses to avoid starting on top of a volume that
# is still attached, so both exits matter: released, and never released.
FAKE_MOUNT_TABLE='fake://vol on /mnt/wait (fake)'
FAKE_MOUNT_CALLS="$_tmp/mount.calls"
: >"$FAKE_MOUNT_CALLS"
FAKE_MOUNT_UNTIL=2
if svc_wait_mount_released /mnt/wait 10; then
  assert_pass "a mount that is released while it is waited on returns success"
else
  assert_fail "svc-wait-mount-released" "the wait failed although the table stopped listing the path"
fi
FAKE_MOUNT_UNTIL=''
if svc_wait_mount_released /mnt/wait 1; then
  assert_fail "svc-wait-mount-timeout" "a path that never leaves the table was reported as released"
else
  assert_pass "a mount that never releases reports the timeout"
fi
# wait_released_rc <path> <timeout> — status of the mount release wait.
wait_released_rc() { # <path> <timeout>
  local _rc=0
  svc_wait_mount_released "$1" "$2" || _rc=$?
  printf '%s' "$_rc"
}

FAKE_MOUNT_TABLE='fake://vol on /mnt/other (fake)'
assert_eq "a path that is not mounted needs no wait" "0" "$(wait_released_rc /mnt/absent 1)"
FAKE_MOUNT_TABLE=''

if [ -n "$(svc_boot_id)" ]; then
  assert_pass "the boot id is reported"
else
  assert_fail "svc-boot-id" "svc_boot_id printed nothing"
fi

section "svc-instances" "bounded relaunch until the volume attaches"

# Instant sleep, scoped to this section: the relaunch loop sleeps between
# launches, and the section before this one asserts a probe that outlives its
# bound, which needs a mount stub that really blocks.
mkdir -p "$_tmp/fastbin"
cat >"$_tmp/fastbin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "$_tmp/fastbin/sleep"
_path_before="$PATH"
PATH="$_tmp/fastbin:$PATH"
export PATH

# WHY: FSKit can refuse the first attempts right after its daemon restarts, so
# the relaunch is bounded twice — by the launch cap and by the budget — and a
# launch that is still in flight is never interrupted.
relaunch_rc() { # <path> <budget> [interval] [max-launches]
  local _rc=0
  svc_remount_until "$1" "gui/501/local.cloud-mount.iCloud" "" "$2" "${3:-5}" "${4:-4}" || _rc=$?
  printf '%s' "$_rc"
}
kick_count() {
  local _kicks
  _kicks="$(cat "$FAKE_KICK_CALLS" 2>/dev/null)"
  [ -n "$_kicks" ] || _kicks=0
  printf '%s' "$_kicks"
}

: >"$FAKE_KICK_CALLS"
: >"$FAKE_ATTEMPT_LIVE"
FAKE_MOUNT_TABLE='fake://vol on /mnt/relaunch (fake)'
assert_eq "an attached volume is never relaunched" "0|0" "$(relaunch_rc /mnt/relaunch 20)|$(kick_count)"

# The attempt ends by itself (the agent stops on a refusal), so the next launch
# is a new one: the volume appears once the provider has served two of them.
: >"$FAKE_KICK_CALLS"
: >"$FAKE_ATTEMPT_LIVE"
FAKE_MOUNT_TABLE='fake://vol on /mnt/relaunch (fake)'
FAKE_MOUNT_AFTER_KICKS=2
assert_eq "a volume that attaches after two launches is awaited, not failed" "0|2" "$(relaunch_rc /mnt/relaunch 40)|$(kick_count)"

# An attempt that is still in flight is left to its own attach bound.
FAKE_JOB_ALWAYS=running
: >"$FAKE_KICK_CALLS"
FAKE_MOUNT_AFTER_KICKS=99
assert_eq "a launch in flight is never interrupted" "1|0" "$(relaunch_rc /mnt/relaunch 10)|$(kick_count)"

# WHY: the probe reads `launchctl print` through a pipe, and a reader that stops
# at its first match SIGPIPEs that writer; under `set -o pipefail` the pipeline
# then reports failure and the loop kicked a launch that was still in flight.
# The padding makes the window deterministic instead of load-dependent.
FAKE_JOB_BULK=20000
: >"$FAKE_KICK_CALLS"
assert_eq "an in-flight launch survives a probe whose output outruns its reader" "1|0" "$(relaunch_rc /mnt/relaunch 10)|$(kick_count)"
FAKE_JOB_BULK=""
FAKE_JOB_ALWAYS=""

# The budget stops the relaunch even when the volume never appears.
: >"$FAKE_KICK_CALLS"
: >"$FAKE_ATTEMPT_LIVE"
assert_eq "the budget bounds the relaunch" "1|2" "$(relaunch_rc /mnt/absent 20)|$(kick_count)"

# The launch cap bounds it too, for a provider that never serves the volume.
: >"$FAKE_KICK_CALLS"
: >"$FAKE_ATTEMPT_LIVE"
assert_eq "the launch cap bounds the relaunch" "1|3" "$(relaunch_rc /mnt/absent 100)|$(kick_count)"
FAKE_MOUNT_AFTER_KICKS=""
FAKE_MOUNT_TABLE=""
PATH="$_path_before"
export PATH

finish_tests
