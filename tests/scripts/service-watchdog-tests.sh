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
        "type": "macos-launchctl",
        "prefixMatch": true,
        "service": "local.cloud-mount.",
        "scope": "user",
        "launchdDomain": "gui"
      },
      "NixOS": {
        "type": "nixos-systemctl",
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
# A booted-out label is reported absent until it is bootstrapped again: the
# recovery helper waits out the unload (macOS 26+ unloads asynchronously) before
# it reloads the job, so the stub has to model that unload.
cat >"$_tmp/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
_booted_out="${FAKE_BOOTED_OUT:?}"
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LIVE:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  if [ -f "$_booted_out" ] && grep -qxF "${2:-}" "$_booted_out"; then
    printf 'Service is not found\n'
    exit 1
  fi
  for _label in ${FAKE_LIVE:-}; do
    case "${2:-}" in
    *"$_label")
      printf 'state = %s\n\tpid = 4242\n' "${FAKE_STATE:-running}"
      if [ -n "${FAKE_EXIT_CODE:-}" ]; then
        printf '\tlast exit code = %s\n' "$FAKE_EXIT_CODE"
      fi
      exit 0
      ;;
    esac
  done
  printf 'Service is not found\n'
  exit 1
  ;;
bootout)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  printf '%s\n' "${*: -1}" >>"$_booted_out"
  ;;
bootstrap)
  printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
  : >"$_booted_out"
  ;;
kickstart | enable | disable | kill)
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

# --- Fake plist dump, mount table, and sleep -------------------------------
#   plutil — prints FAKE_PLIST_KEYS, which is how a launchd plist's
#            KeepAlive { SuccessfulExit = false } contract is declared here.
#   mount  — reports FAKE_MOUNT_TABLE: the cloud mount that a reload must not
#            start on top of.
#   sleep  — instant, so the watcher's 30 s mount-release bound costs no wall
#            clock (the watchdog polls it while waiting for the volume).
cat >"$_tmp/bin/plutil" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PLIST_KEYS:-}"
FAKE
cat >"$_tmp/bin/mount" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_MOUNT_TABLE:-}"
FAKE
cat >"$_tmp/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$_tmp/bin/plutil" "$_tmp/bin/mount" "$_tmp/bin/sleep"

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
    FAKE_EXIT_CODE="${FAKE_EXIT_CODE:-}" \
    FAKE_PLIST_KEYS="${FAKE_PLIST_KEYS:-}" \
    FAKE_MOUNT_TABLE="${FAKE_MOUNT_TABLE:-}" \
    FAKE_SYSTEMCTL_STATE="${FAKE_SYSTEMCTL_STATE:-active}" \
    FAKE_LAUNCHCTL_LOG="$_tmp/launchctl.log" \
    FAKE_SYSTEMCTL_LOG="$_tmp/systemctl.log" \
    FAKE_BOOTED_OUT="$_tmp/booted-out.txt" \
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
: >"$_tmp/booted-out.txt"
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

section 8 "A cleanly exited KeepAlive job is reloaded"

# WHY: a launchd job whose process exits 0 is never retried by
# KeepAlive{SuccessfulExit:false}, so nothing brings a cloud mount back after a
# reload that left it stopped. The plist decides: only a job that declares that
# contract may be reloaded, or the watchdog would fight periodic agents.
_plist_dir="$_tmp/home/Library/LaunchAgents"
mkdir -p "$_plist_dir"
printf 'plist placeholder\n' >"$_plist_dir/local.cloud-mount.iCloud.plist"
FAKE_LIVE="local.cloud-mount.iCloud"
FAKE_STATE="not running"
FAKE_EXIT_CODE=0
FAKE_PLIST_KEYS="KeepAlive = { SuccessfulExit = false }"
FAKE_MOUNT_TABLE="fake://vol on $_tmp/home/clouds/OneDrive (fake, nodev)"
SUDO_USER_OVERRIDE=test-user
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a cleanly exited job exits 0" 0 "$captured_status"
assert_contains "the cleanly exited job is booted out" "$(cat "$_tmp/launchctl.log")" "bootout"
assert_contains "the cleanly exited job is bootstrapped again" "$(cat "$_tmp/launchctl.log")" "bootstrap"
assert_contains "the recovered target is that instance" "$(cat "$_tmp/launchctl.log")" "local.cloud-mount.iCloud"
assert_contains "the reload reports the clean exit" "$captured_output" "restarted local.cloud-mount.iCloud (clean exit)"

section 9 "A crash-looping clean exit is not reloaded"

mkdir -p "$state_dir"
jq -n --argjson now "$(date +%s)" '{restarts: [range($now - 11; $now + 1)], lastSuccess: 0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"
: >"$_tmp/launchctl.log"
run_capture
assert_eq "a crash-looping clean exit exits 0" 0 "$captured_status"
assert_eq "a crash-looping clean exit is not touched" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_contains "the crash loop is reported for the clean exit" "$captured_output" "crash-looping"
rm -f "$state_dir/local.cloud-mount.iCloud.json"

section 10 "Jobs without the clean-exit contract are left alone"

for _keys in "RunAtLoad = 1" "KeepAlive = 1"; do
  FAKE_PLIST_KEYS="$_keys"
  : >"$_tmp/launchctl.log"
  run_capture
  assert_eq "$_keys exits 0" 0 "$captured_status"
  assert_eq "$_keys is never reloaded by the watchdog" 0 "$(calls_made "$_tmp/launchctl.log")"
  assert_not_contains "$_keys is not reported as restarted" "$captured_output" "restarted"
done
rm -f "$_plist_dir/local.cloud-mount.iCloud.plist"
: >"$_tmp/launchctl.log"
run_capture
assert_eq "a missing plist exits 0" 0 "$captured_status"
assert_eq "a missing plist is never reloaded" 0 "$(calls_made "$_tmp/launchctl.log")"

section 11 "A mount that never releases is not reloaded over"

# WHY: the release wait is what keeps a reload from starting a second mount on
# top of a volume that is still attached, so the assertion is about the mount
# the instance owns, not about the watchdog in general.
printf 'plist placeholder\n' >"$_plist_dir/local.cloud-mount.iCloud.plist"
FAKE_LIVE="local.cloud-mount.iCloud"
FAKE_STATE="not running"
FAKE_EXIT_CODE=0
FAKE_PLIST_KEYS="KeepAlive = { SuccessfulExit = false }"
SUDO_USER_OVERRIDE=test-user
FAKE_MOUNT_TABLE="fake://vol on $_tmp/home/clouds/iCloud (fake, nodev)"
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a never-released mount exits 0" 0 "$captured_status"
assert_eq "a never-released mount is not reloaded over" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_contains "the never-released mount is reported" "$captured_output" "still mounted"

# The released shape of the same fixture: the same instance does reload once the
# volume is gone, so the assertion above is about the mount, not the watchdog.
FAKE_MOUNT_TABLE="fake://vol on $_tmp/home/clouds/OneDrive (fake, nodev)"
: >"$_tmp/launchctl.log"
run_capture
assert_contains "the released mount is reloaded" "$(cat "$_tmp/launchctl.log")" "bootstrap"

section 12 "A deliberately blocked instance is left alone"

# WHY: a cloud mount whose macFUSE/FSKit provider refuses it stops on purpose —
# rclone-mount.sh records a blocked marker and exits 0, so
# KeepAlive{SuccessfulExit:false} keeps it stopped — and the watchdog must
# report it once instead of reloading it on every 300 s tick: each reload
# attempt re-registers the file-system extension and deepens the wedge.

# current_boot_id — The boot id the runtime records in a blocked marker.
# Mirrors svc_boot_id, including its "unknown" fallback: a probe that the host
# refuses (sysctl is not always permitted) must not make a fresh marker look
# stale here while the runtime reads it as fresh.
current_boot_id() {
  local boot=""
  case "$(uname -s)" in
  Darwin) [ -x /usr/sbin/sysctl ] && boot="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || true)" ;;
  Linux) [ -r /proc/sys/kernel/random/boot_id ] && boot="$(cat /proc/sys/kernel/random/boot_id)" ;;
  esac
  [ -n "$boot" ] || boot="unknown"
  printf '%s\n' "$boot"
}

# write_blocked_marker — Seed the marker a deliberately stopped instance left.
# Args: $1 — instance id; $2 — class; $3 — boot id (default: the current boot).
# The boot id is read from the same probe the runtime uses, so freshness is
# decided by the real comparison rather than by a stubbed one.
write_blocked_marker() {
  mkdir -p "$state_dir"
  {
    printf 'class=%s\n' "$2"
    printf 'remedy=%s\n' "run 'sudo killall fskitd' (nucleus-cloud repair)"
    printf 'boot=%s\n' "${3:-$(current_boot_id)}"
    printf 'ts=%s\n' "$(date +%s)"
  } >"$state_dir/$1.blocked"
}

# drop_blocked_marker — What the runtime does once the instance converges: the
# library drops the marker and the report record together, which is what makes a
# later block a new transition.
drop_blocked_marker() {
  rm -f "$state_dir/$1.blocked" "$state_dir/$1.blocked-reported"
}

# block_reports — Number of block reports held in a captured output block.
block_reports() {
  printf '%s\n' "$1" | grep -c ' is blocked (' || true
}

printf 'plist placeholder\n' >"$_plist_dir/local.cloud-mount.iCloud.plist"
FAKE_LIVE="local.cloud-mount.iCloud"
FAKE_STATE="not running"
FAKE_EXIT_CODE=0
FAKE_PLIST_KEYS="KeepAlive = { SuccessfulExit = false }"
FAKE_MOUNT_TABLE="fake://vol on $_tmp/home/clouds/GoogleDrive (fake, nodev)"
SUDO_USER_OVERRIDE=test-user
drop_blocked_marker local.cloud-mount.iCloud
write_blocked_marker local.cloud-mount.iCloud fskit-provider
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a blocked instance exits 0" 0 "$captured_status"
assert_eq "a blocked instance is never reloaded" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "the block is reported once" 1 "$(block_reports "$captured_output")"
assert_contains "the report names the instance and its class" "$captured_output" \
  "local.cloud-mount.iCloud is blocked (fskit-provider)"
assert_contains "the report names the remedy" "$captured_output" "killall fskitd"

run_capture
assert_eq "a repeated tick is silent about the block" 0 "$(block_reports "$captured_output")"
assert_eq "a repeated tick does not reload it" 0 "$(calls_made "$_tmp/launchctl.log")"

drop_blocked_marker local.cloud-mount.iCloud
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a cleared block exits 0" 0 "$captured_status"
assert_contains "the instance is reloaded once the block is gone" "$(cat "$_tmp/launchctl.log")" "bootstrap"

write_blocked_marker local.cloud-mount.iCloud fskit-provider
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a later block is reported again" 1 "$(block_reports "$captured_output")"
assert_eq "a later block is not reloaded" 0 "$(calls_made "$_tmp/launchctl.log")"

# A marker written in an earlier boot is stale: the standing remedy for a wedged
# provider is a daemon restart or a reboot, so a reboot must not keep the
# instance down.
write_blocked_marker local.cloud-mount.iCloud fskit-provider other-boot
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a marker from an earlier boot exits 0" 0 "$captured_status"
assert_eq "a marker from an earlier boot is not reported" 0 "$(block_reports "$captured_output")"
assert_contains "a marker from an earlier boot does not suppress the reload" \
  "$(cat "$_tmp/launchctl.log")" "bootstrap"

# One blocked instance must not silence the others in the same tick.
drop_blocked_marker local.cloud-mount.iCloud
printf 'plist placeholder\n' >"$_plist_dir/local.cloud-mount.OneDrive.plist"
write_blocked_marker local.cloud-mount.iCloud fskit-provider
FAKE_LIVE="local.cloud-mount.iCloud local.cloud-mount.OneDrive"
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_capture
assert_eq "a mixed tick exits 0" 0 "$captured_status"
assert_contains "the blocked instance is reported beside another" "$captured_output" \
  "local.cloud-mount.iCloud is blocked (fskit-provider)"
assert_contains "the unblocked instance is still recovered" "$(cat "$_tmp/launchctl.log")" \
  "local.cloud-mount.OneDrive"
assert_not_contains "the blocked instance is skipped beside it" "$(cat "$_tmp/launchctl.log")" \
  "local.cloud-mount.iCloud"

drop_blocked_marker local.cloud-mount.iCloud
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
write_blocked_marker cloud-mount-iCloud.service fskit-provider
WATCHDOG_TEST_HOST=NixOS
FAKE_UNITS="cloud-mount-iCloud.service"
FAKE_SYSTEMCTL_STATE="failed"
FAKE_LIVE=""
: >"$_tmp/systemctl.log"
run_capture
assert_eq "a blocked NixOS unit exits 0" 0 "$captured_status"
assert_eq "a blocked NixOS unit is not restarted" 0 "$(calls_made "$_tmp/systemctl.log")"
assert_contains "the blocked NixOS unit is reported" "$captured_output" \
  "cloud-mount-iCloud.service is blocked (fskit-provider)"
WATCHDOG_TEST_HOST=
FAKE_UNITS=""
FAKE_SYSTEMCTL_STATE=""
rm -f "$state_dir/cloud-mount-iCloud.service.blocked" "$state_dir/cloud-mount-iCloud.service.blocked-reported"

finish_tests
