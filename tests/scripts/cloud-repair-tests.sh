#!/usr/bin/env bash
# nucleus-cloud repair — FSKit provider repair, the mount restarts it drives, and
# the verification that ends it.
#
# WHY: a wedged macOS FSKit subsystem makes every mount attempt fail with "File
# system extension not found"/"not enabled" (macFUSE status 3/4) or "mount(8)
# returned 69" while the drive is simply missing, and the only repair is the
# FSKit daemon restart. The regressions this guards: repairing a host with no
# FSKit provider, starting mounts after a failed provider repair, unmounting a
# mount that is already healthy (the remount is what wedges FSKit), reporting
# success for a mount that never came back, and leaving the blocked marker
# behind after a successful repair.
# ref: https://github.com/macfuse/macfuse/issues/1132
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/crash-loop.sh
. "$REPO_ROOT/src/scripts/lib/crash-loop.sh"
# shellcheck source=../../src/scripts/lib/svc-instances.sh
. "$REPO_ROOT/src/scripts/lib/svc-instances.sh"

require_command jq "nucleus-cloud repair parses the user registry with jq"

CLOUD_SH="$REPO_ROOT/scripts/cloud.sh"
# The host is auto-detected (uname is stubbed below), so the suite exercises the
# macOS path on any machine and never touches this host's real launchd state.
unset NUCLEUS_HOST

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"
FAKE_HOME="$_tmp/home"
mkdir -p "$FAKE_HOME/Library/Group Containers/group.com.apple.fskit.settings" \
  "$FAKE_HOME/Library/LaunchAgents"
: >"$FAKE_HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
_out="$_tmp/out.txt"

# --- Fixture repo ------------------------------------------------------------
# A repo root with only what the user-registry loader needs: the root is passed
# with --repo-root, so the suite never reads the real user's registry.
FIXTURE_REPO="$_tmp/repo"
mkdir -p "$FIXTURE_REPO/src/modules" "$FIXTURE_REPO/src/users/test-user"
cp "$REPO_ROOT/src/modules/services.json" "$FIXTURE_REPO/src/modules/services.json"
cat >"$FIXTURE_REPO/src/users/test-user/cloud-drives.json" <<'JSON'
{
  "mounts": [
    { "id": "GoogleDrive", "localPath": "clouds/GoogleDrive", "remoteName": "GoogleDrive" },
    { "id": "OneDrive", "localPath": "clouds/OneDrive", "remoteName": "OneDrive" },
    { "enable": false, "id": "Disabled", "localPath": "clouds/Disabled", "remoteName": "Disabled" }
  ]
}
JSON

# --- Fake toolchain ----------------------------------------------------------
# Every command the repair touches is faked: the suite must never restart a real
# FSKit daemon, kickstart a real agent, or read this host's mount table.
#   FAKE_MOUNT_MAP      — label<TAB>mount point, so a restart can "mount" a path.
#   FAKE_JOBS_LOADED    — labels launchd reports as loaded.
#   FAKE_MOUNTS         — the fake mount table.
#   FAKE_ACTIONS        — ordered action log (killall/kickstart/bootstrap).
#   FAKE_KILLALL_STATUS — non-zero models a failed daemon restart.
#   FAKE_DAEMON_KILLED  — set once killall ran; the FSKit daemon answers a new pid.
#   FAKE_UNAME_S        — the platform the repair sees.
#   FAKE_NO_MOUNT_ON_KICKSTART — a restarted agent whose mount never appears.
#   FAKE_ATTACH_AFTER_KICKS — the volume appears only from this launch on, which
#                      is how FSKit looks when it refuses the first attempts and
#                      serves a later one.
FAKE_MOUNT_MAP="$_tmp/mount-map"
FAKE_JOBS_LOADED="$_tmp/jobs-loaded"
FAKE_MOUNTS="$_tmp/mounts"
FAKE_ACTIONS="$_tmp/actions"
FAKE_LAUNCHCTL_LOG="$_tmp/launchctl.log"
FAKE_DAEMON_KILLED="$_tmp/daemon-killed"
FAKE_KICK_COUNT="$_tmp/kick-count"
FAKE_KILLALL_STATUS=0
FAKE_NO_MOUNT_ON_KICKSTART=0
FAKE_ATTACH_AFTER_KICKS=""
FAKE_UNAME_S=Darwin
export FAKE_MOUNT_MAP FAKE_JOBS_LOADED FAKE_MOUNTS FAKE_ACTIONS FAKE_LAUNCHCTL_LOG
export FAKE_DAEMON_KILLED FAKE_KICK_COUNT FAKE_KILLALL_STATUS FAKE_NO_MOUNT_ON_KICKSTART
export FAKE_ATTACH_AFTER_KICKS FAKE_UNAME_S

printf 'local.cloud-mount.GoogleDrive\t%s\n' "$FAKE_HOME/clouds/GoogleDrive" >"$FAKE_MOUNT_MAP"
printf 'local.cloud-mount.OneDrive\t%s\n' "$FAKE_HOME/clouds/OneDrive" >>"$FAKE_MOUNT_MAP"

cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
_attach() { # <label> — a restarted agent mounts its configured path
  local _path
  _path="$(awk -v l="$1" '$1 == l { print $2 }' "$FAKE_MOUNT_MAP")"
  if [ -n "$_path" ]; then printf 'fake://vol on %s (macfuse)\n' "$_path" >>"$FAKE_MOUNTS"; fi
}
case "${1:-}" in
print)
  case "${2:-}" in
  system/*)
    # The FSKit daemon: it reports a pid, and a pid different from the one before
    # only once it was killed — which is what fskit_restart_daemon waits for.
    if [ -f "$FAKE_DAEMON_KILLED" ]; then
      printf 'pid = %s\n' "$((2000 + $(wc -l <"$FAKE_LAUNCHCTL_LOG")))"
    else
      printf 'pid = 1000\n'
    fi
    exit 0
    ;;
  esac
  _label="${2##*/}"
  # An agent whose attempt the provider refused has already exited by the time it
  # is probed again, so only an attempt that was served (or one with no refusal
  # modelled) reports the job as running.
  if grep -qxF "$_label" "$FAKE_JOBS_LOADED" 2>/dev/null; then
    _kicks="$(cat "$FAKE_KICK_COUNT" 2>/dev/null || printf '0')"
    _refused=false
    [ "$FAKE_NO_MOUNT_ON_KICKSTART" = "1" ] && _refused=true
    if [ -n "${FAKE_ATTACH_AFTER_KICKS:-}" ] && [ "$_kicks" -lt "$FAKE_ATTACH_AFTER_KICKS" ]; then
      _refused=true
    fi
    if [ "$_refused" = false ]; then
      printf 'state = running\n\tpid = 4242\n'
      exit 0
    fi
  fi
  printf 'Could not find service\n' >&2
  exit 113
  ;;
kickstart)
  _label="${3##*/}"
  printf 'kickstart %s\n' "$_label" >>"$FAKE_ACTIONS"
  printf '%s\n' "$_label" >>"$FAKE_JOBS_LOADED"
  _kicks="$(cat "$FAKE_KICK_COUNT" 2>/dev/null || printf '0')"
  _kicks=$((_kicks + 1))
  printf '%s' "$_kicks" >"$FAKE_KICK_COUNT"
  _serves=true
  [ "$FAKE_NO_MOUNT_ON_KICKSTART" = "1" ] && _serves=false
  if [ -n "${FAKE_ATTACH_AFTER_KICKS:-}" ] && [ "$_kicks" -lt "$FAKE_ATTACH_AFTER_KICKS" ]; then
    _serves=false
  fi
  if [ "$_serves" = true ]; then _attach "$_label"; fi
  exit 0
  ;;
bootstrap)
  _label="$(basename "${3%.plist}")"
  printf 'bootstrap %s\n' "$_label" >>"$FAKE_ACTIONS"
  printf '%s\n' "$_label" >>"$FAKE_JOBS_LOADED"
  _attach "$_label"
  exit 0
  ;;
esac
exit 0
FAKE_LAUNCHCTL

cat >"$_tmp/bin/killall" <<'FAKE_KILLALL'
#!/usr/bin/env bash
printf 'killall %s\n' "$*" >>"$FAKE_ACTIONS"
if [ "$FAKE_KILLALL_STATUS" -ne 0 ]; then
  printf 'killall: no process found\n' >&2
  exit "$FAKE_KILLALL_STATUS"
fi
: >"$FAKE_DAEMON_KILLED"
exit 0
FAKE_KILLALL

cat >"$_tmp/bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
exec "$@"
FAKE_SUDO

cat >"$_tmp/bin/plutil" <<'FAKE_PLUTIL'
#!/usr/bin/env bash
case "${1:-}" in
-p)
  printf '  5 => "io.macfuse.app.fsmodule.macfuse"\n'
  exit 0
  ;;
esac
exit 1
FAKE_PLUTIL

cat >"$_tmp/bin/mount" <<'FAKE_MOUNT'
#!/usr/bin/env bash
cat "$FAKE_MOUNTS"
FAKE_MOUNT

# The repair waits for mounts over a bounded window; the fake makes that wait
# cost no wall-clock time.
cat >"$_tmp/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP

cat >"$_tmp/bin/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_UNAME_S"
FAKE_UNAME

# The fixture user is a test identity, never the invoking user.
cat >"$_tmp/bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
case "${1:-}" in
-un) printf 'test-user\n' ;;
*) printf '501\n' ;;
esac
FAKE_ID

chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/killall" "$_tmp/bin/sudo" "$_tmp/bin/plutil" \
  "$_tmp/bin/mount" "$_tmp/bin/sleep" "$_tmp/bin/uname" "$_tmp/bin/id"
PATH="$_tmp/bin:$PATH"
export PATH

# The repair resolves its state directory from the platform it sees, so the suite
# has to derive the same path through the same stubbed uname: derive it here, with
# the fake toolchain on PATH, rather than against the host's own uname.
STATE_DIR="$(HOME="$FAKE_HOME" crash_loop_state_dir)"
mkdir -p "$STATE_DIR"

assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

assert_mentions() { # <slug> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1 mentions '$3'" ;;
  *) assert_fail "$1" "output did not mention '$3': $2" ;;
  esac
}

assert_actioned() { # <slug> <label>
  if grep -qxF "kickstart $2" "$FAKE_ACTIONS" || grep -qxF "bootstrap $2" "$FAKE_ACTIONS"; then
    assert_pass "$1: $2 was restarted"
  else
    assert_fail "$1" "$2 was never restarted; actions: $(tr '\n' '|' <"$FAKE_ACTIONS")"
  fi
}

assert_untouched() { # <slug> <label>
  if grep -qxF "kickstart $2" "$FAKE_ACTIONS" || grep -qxF "bootstrap $2" "$FAKE_ACTIONS"; then
    assert_fail "$1" "$2 was restarted although it must not be; actions: $(tr '\n' '|' <"$FAKE_ACTIONS")"
  else
    assert_pass "$1: $2 was left alone"
  fi
}

# run_repair <args...> — invoke nucleus-cloud repair against the fixture repo.
# Prints the exit status; output is left in $_out.
run_repair() {
  _rc=0
  env -u NUCLEUS_HOST -u NUCLEUS_USER_ROOT HOME="$FAKE_HOME" \
    bash "$CLOUD_SH" repair --repo-root "$FIXTURE_REPO" "$@" >"$_out" 2>&1 || _rc=$?
  printf '%s' "$_rc"
}

# reset_world <loaded-labels...> — fresh state: nothing mounted, given labels loaded.
reset_world() {
  : >"$FAKE_LAUNCHCTL_LOG"
  : >"$FAKE_ACTIONS"
  : >"$FAKE_JOBS_LOADED"
  printf 'fake://root on / (fake)\n' >"$FAKE_MOUNTS"
  rm -f "$FAKE_DAEMON_KILLED"
  : >"$FAKE_KICK_COUNT"
  rm -f "$STATE_DIR"/*.blocked
  rm -f "$FAKE_HOME/Library/LaunchAgents"/*.plist
  for _label in "$@"; do printf '%s\n' "$_label" >>"$FAKE_JOBS_LOADED"; done
  FAKE_KILLALL_STATUS=0
  FAKE_NO_MOUNT_ON_KICKSTART=0
  FAKE_ATTACH_AFTER_KICKS=""
  FAKE_UNAME_S=Darwin
  export FAKE_KILLALL_STATUS FAKE_NO_MOUNT_ON_KICKSTART FAKE_ATTACH_AFTER_KICKS FAKE_UNAME_S
}

# mark_blocked <label> — a fresh blocked marker, as the mount wrapper leaves it.
mark_blocked() {
  svc_blocked_set "$1" "$STATE_DIR" fskit-provider "run sudo killall fskitd"
}

section "1" "host and provider gates"

reset_world local.cloud-mount.OneDrive
FAKE_UNAME_S=Linux
export FAKE_UNAME_S
assert_eq "a non-macOS host is rejected" "1" "$(run_repair)"
assert_mentions "the rejection" "$(cat "$_out")" "FSKit provider"
assert_mentions "the rejection names the host" "$(cat "$_out")" "NixOS"
assert_untouched "a rejected host" local.cloud-mount.OneDrive

reset_world local.cloud-mount.OneDrive
FAKE_KILLALL_STATUS=1
export FAKE_KILLALL_STATUS
assert_eq "a failed provider repair fails the command" "1" "$(run_repair)"
assert_mentions "the failed provider repair" "$(cat "$_out")" "killall fskitd"
assert_untouched "a failed provider repair" local.cloud-mount.OneDrive

section "2" "repair brings the mounts back"

reset_world local.cloud-mount.GoogleDrive local.cloud-mount.OneDrive
mark_blocked local.cloud-mount.OneDrive
if [ -f "$STATE_DIR/local.cloud-mount.OneDrive.blocked" ]; then
  assert_pass "the blocked marker is in place before the repair"
else
  assert_fail "cloud-repair-precondition" "the blocked marker was not written"
fi
assert_eq "a repaired host exits 0" "0" "$(run_repair)"
assert_actioned "the repair" local.cloud-mount.OneDrive
assert_actioned "the repair" local.cloud-mount.GoogleDrive
assert_mentions "the repair" "$(cat "$_out")" "mounted: OneDrive"
if [ -e "$STATE_DIR/local.cloud-mount.OneDrive.blocked" ]; then
  assert_fail "cloud-repair-clears-marker" "the blocked marker survived the repair"
else
  assert_pass "the repair clears the blocked marker"
fi
assert_untouched "a disabled mount" local.cloud-mount.Disabled
# WHY: the daemon restart is what unwedges FSKit, so it has to happen before any
#   mount attempt — a start on a stale subsystem is what fails with status 3/4.
if [ "$(grep -n '^killall fskitd$' "$FAKE_ACTIONS" | head -n1 | cut -d: -f1)" = "1" ]; then
  assert_pass "the daemon restart comes before the mount restarts"
else
  assert_fail "cloud-repair-order" "actions: $(tr '\n' '|' <"$FAKE_ACTIONS")"
fi

section "3" "mounts that need no repair"

reset_world local.cloud-mount.OneDrive
printf 'fake://vol on %s (macfuse)\n' "$FAKE_HOME/clouds/OneDrive" >>"$FAKE_MOUNTS"
assert_eq "an already mounted drive exits 0" "0" "$(run_repair OneDrive)"
assert_mentions "an already mounted drive" "$(cat "$_out")" "already mounted"
assert_untouched "an already mounted drive" local.cloud-mount.OneDrive

reset_world
: >"$FAKE_HOME/Library/LaunchAgents/local.cloud-mount.OneDrive.plist"
assert_eq "an unloaded agent with a plist is loaded" "0" "$(run_repair OneDrive)"
assert_mentions "the loaded agent" "$(cat "$FAKE_ACTIONS")" "bootstrap local.cloud-mount.OneDrive"
assert_mentions "the loaded agent's mount" "$(cat "$_out")" "mounted: OneDrive"

section "4" "mounts that never come back"

reset_world local.cloud-mount.OneDrive
FAKE_NO_MOUNT_ON_KICKSTART=1
export FAKE_NO_MOUNT_ON_KICKSTART
assert_eq "a mount that never appears fails the command" "1" "$(run_repair OneDrive --timeout 2)"
assert_mentions "an unrecovered mount" "$(cat "$_out")" "not mounted: OneDrive"
assert_mentions "an unrecovered mount reports the remedy" "$(cat "$_out")" "killall fskitd"
assert_eq "the bounded wait is validated" "1" "$(run_repair OneDrive --timeout 0)"

reset_world local.cloud-mount.OneDrive
assert_eq "an undeclared mount id is rejected" "1" "$(run_repair Nonexistent)"
assert_mentions "an undeclared mount id" "$(cat "$_out")" "not declared"

section "5" "a provider that serves the volume on a later attempt"

# WHY: FSKit refuses the first attempts right after its daemon restarts, and the
#   agent stops on a refusal instead of retrying it, so the repair has to launch
#   the agent again inside its bound rather than probe once.
reset_world local.cloud-mount.OneDrive
FAKE_ATTACH_AFTER_KICKS=2
export FAKE_ATTACH_AFTER_KICKS
assert_eq "a volume served on a later attempt still comes back" "0" "$(run_repair OneDrive --timeout 40)"
assert_mentions "the relaunched mount" "$(cat "$_out")" "mounted: OneDrive"
assert_eq "the repair launched the agent again" "2" "$(grep -c '^kickstart local.cloud-mount.OneDrive$' "$FAKE_ACTIONS")"
FAKE_ATTACH_AFTER_KICKS=""
export FAKE_ATTACH_AFTER_KICKS

finish_tests
