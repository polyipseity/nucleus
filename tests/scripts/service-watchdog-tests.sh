#!/usr/bin/env bash
# Tests for src/scripts/services/service-watchdog.sh — the rewritten watchdog
# with canonical instance keys, svc_health_* records, and health-record-driven
# loop detection.
#
# Tests exercise _watchdog_check_instance and _watchdog_check_prefix directly
# (the main loop in _watchdog_tick has pre-existing bugs: get_nucleus_host_key
# does not exist and svc_keys is overwritten inside the for-loop).  Each test
# seeds a svc_health record, configures fake launchctl/systemctl via PATH, and
# asserts the correct supervisor actions and notice output.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "service watchdog tests build health records with jq"

WATCHDOG="$REPO_ROOT/src/scripts/services/service-watchdog.sh"
SERVICE_HEALTH="$REPO_ROOT/src/scripts/lib/service-health.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin" "$_tmp/home" "$_tmp/repo/src/modules"

# HOME must point into the temp tree so derive_nucleus_user_root resolves
# the state directory inside our temp sandbox.
HOME="$_tmp/home"
export HOME

# Stub services.json for prefix expansion tests.
cat >"$_tmp/repo/src/modules/services.json" <<'JSON'
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

# ── Fake launchctl ──────────────────────────────────────────────────────────
# FAKE_LIVE — space-separated labels the fake considers loaded.
# FAKE_STATE — the "state = ..." value printed by launchctl print.
# FAKE_EXIT_CODE — optional "last exit code" line.
# FAKE_DISABLED — space-separated labels whose "print" returns "not found"
#   (models a user-disabled job, satisfying supervisor_enabled=false).
# FAKE_LAUNCHCTL_LOG — file where mutating calls are appended.
cat >"$_tmp/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
_booted_out="${FAKE_BOOTED_OUT:-/dev/null}"
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for _label in ${FAKE_LIVE:-}; do printf '4242\t0\t%s\n' "$_label"; done
  ;;
print)
  # Disabled services: supervisor_enabled returns false (Rule 1).
  for _d in ${FAKE_DISABLED:-}; do
    if [ "${2:-}" = "$_d" ] || [ "${2:-}" = *"/$_d" ]; then
      printf 'Could not find service "%s"\n' "${2:-}"
      exit 1
    fi
  done
  # Booted-out labels are temporarily absent (models async bootout on macOS 26+).
  if [ -f "$_booted_out" ] && grep -qxF "${2:-}" "$_booted_out"; then
    printf 'Could not find service "%s"\n' "${2:-}"
    exit 1
  fi
  for _label in ${FAKE_LIVE:-}; do
    case "${2:-}" in
    *"$_label")
      printf 'state = %s\n\tpid = 4242\n\truns = %s\n\tlast exit code = %s\n' \
        "${FAKE_STATE:-running}" "${FAKE_RUNS:-1}" "${FAKE_EXIT_CODE:-0}"
      exit 0
      ;;
    esac
  done
  printf 'Could not find service "%s"\n' "${2:-}"
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

# ── Fake systemctl ──────────────────────────────────────────────────────────
# FAKE_UNITS — space-separated unit names the fake reports as loaded.
# FAKE_SYSTEMCTL_STATE — "active" or "failed" for is-active.
# FAKE_SYSTEMCTL_LOG — file where mutating calls are appended.
cat >"$_tmp/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
*" list-units "*)
  for _unit in ${FAKE_UNITS:-}; do printf '%s loaded active running\n' "$_unit"; done
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
*" status "*)
  # Return status text the supervisor_live parser can read.
  printf 'Active: %s\n' "${FAKE_SYSTEMCTL_STATE:-active}"
  exit 0
  ;;
*" stop "* | *" start "* | *" restart "* | *" reset-failed "*)
  printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
  exit 0
  ;;
esac
exit 1
FAKE

chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/systemctl"
PATH="$_tmp/bin:$PATH"
export PATH

# ── Mock supervisor functions ───────────────────────────────────────────────
# These replace supervisor-launchd.sh / supervisor-systemd.sh so tests run on
# any host.  Behaviour is driven by FAKE_* environment variables and the
# launchctl/systemctl fakes on PATH.
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_enabled() {
  launchctl print "$1" >/dev/null 2>&1
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_live() {
  local print_out="$1"
  case "$print_out" in
  *"state = running"*) return 0 ;;
  esac
  return 1
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_counter() {
  local print_out="$1"
  printf '%s' "$print_out" | awk '/runs =/{print $3; exit}'
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_last_exit() {
  local print_out="$1"
  printf '%s' "$print_out" | awk '/last exit code/{print $4; exit}'
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_stop() {
  launchctl bootout "$1" 2>/dev/null || true
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_start() {
  launchctl bootstrap "$1" 2>/dev/null || true
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_repair() {
  launchctl bootout "$1" 2>/dev/null || true
  launchctl bootstrap "$1" 2>/dev/null || true
}

# ── Mock lib.sh primitives ─────────────────────────────────────────────────
# shellcheck disable=SC2329,SC2120 # reason: mock functions invoked by eval'd watchdog code
derive_repo_root() { printf '%s' "$_tmp/repo"; }
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
get_nucleus_host_key() { printf '%s' "${NUCLEUS_HOST:-MacBook}"; }
NUCLEUS_HOST=MacBook

# ── Extract watchdog function definitions (avoid executing _watchdog_main) ──
# The script ends with `_watchdog_main "$@"` which would enter an infinite
# loop.  We extract only the function definitions via awk, then re-source
# service-health.sh to restore any functions clobbered by the eval.
eval "$(awk '/^_watchdog_[a-z_]+\(\)/ || /^supervisor_/ { p = 1 } p { print } p && /^}/ { p = 0; next } /^[^_]/ && !/^#/ && !/^$/ && p == 0 { next }' "$WATCHDOG")"
# shellcheck source=../src/scripts/lib/service-health.sh
# shellcheck disable=SC1091 # reason: relative source path resolves at runtime
# shellcheck source=../src/scripts/lib/service-health.sh
. "$SERVICE_HEALTH"

# ── Helpers ─────────────────────────────────────────────────────────────────
state_dir="$(svc_health_state_dir)"

captured_output=""
captured_status=0

# run_check_instance — run _watchdog_check_instance once and capture output.
run_check_instance() {
  captured_status=0
  captured_output="$(
    set +e
    _watchdog_check_instance "$1" "$2" "$3" "$4" 2>&1
  )" || captured_status=$?
}

# run_check_prefix — run _watchdog_check_prefix once and capture output.
run_check_prefix() {
  captured_status=0
  captured_output="$(
    set +e
    _watchdog_check_prefix "$1" "$2" "$3" 2>&1
  )" || captured_status=$?
}

assert_contains() { # <name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1" ;;
  *) assert_fail "$1" "expected output to contain '$3', got: $2" ;;
  esac
}

assert_not_contains() { # <name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_fail "$1" "expected output not to contain '$3', got: $2" ;;
  *) assert_pass "$1" ;;
  esac
}

assert_eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

calls_made() {
  local file="$1"
  if [ -f "$file" ]; then wc -l <"$file" | tr -d ' '; else printf '0'; fi
}

macos_entry='{"type":"macos-launchctl","prefixMatch":true,"service":"local.cloud-mount.","scope":"user","launchdDomain":"gui"}'
nixos_entry='{"type":"nixos-systemctl","prefixMatch":true,"service":"cloud-mount-","scope":"user"}'

# ── Section 1: Healthy instance is left alone ──────────────────────────────
section 1 "Healthy instance is left alone"

FAKE_LIVE="local.cloud-mount.iCloud"
export FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
export FAKE_LIVE FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "healthy exits 0" 0 "$captured_status"
assert_eq "healthy is not touched" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "healthy prints nothing" "" "$captured_output"

# ── Section 2: Stuck instance is noticed (Rule 4) ──────────────────────────
section 2 "Stuck instance triggers revival notice"

FAKE_LIVE="local.cloud-mount.iCloud"
export FAKE_LIVE FAKE_STATE
FAKE_STATE="spawn scheduled"
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "stuck exits 0" 0 "$captured_status"
assert_contains "stuck is noticed" "$captured_output" "not running"

# ── Section 3: Crash-looping instance is blocked (Rule 3) ─────────────────
section 3 "Crash-looping instance is stopped and blocked"

mkdir -p "$state_dir"
# Seed 11 restarts in the last hour → svc_health_is_looping returns 0.
_now=$(date +%s)
_restarts="$(printf '%s\n' $((_now - 3600)) $((_now - 3500)) $((_now - 3400)) $((_now - 3300)) $((_now - 3200)) $((_now - 3100)) $((_now - 3000)) $((_now - 2900)) $((_now - 2800)) $((_now - 2700)) $((_now - 100)) | jq -s '.')"
jq -n --argjson r "$_restarts" --arg boot "$(svc_health_boot_id)" \
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":$r,"runs":5,"lastExit":1}' \
  >"$state_dir/local.cloud-mount.iCloud.json"

FAKE_LIVE="local.cloud-mount.iCloud"
export FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
FAKE_EXIT_CODE=1
export FAKE_EXIT_CODE
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "looping exits 0" 0 "$captured_status"
assert_contains "looping is stopped" "$captured_output" "looping"
assert_contains "looping is bootout'd" "$(cat "$_tmp/launchctl.log")" "bootout"
rm -f "$state_dir/local.cloud-mount.iCloud.json"

# ── Section 4: Blocked record is reported once (Rule 2) ───────────────────
section 4 "Blocked record is reported once, then silent"

mkdir -p "$state_dir"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"blocked","class":"fskit-provider","remedy":"run repair","attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"

FAKE_LIVE="local.cloud-mount.iCloud"
export FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "blocked exits 0" 0 "$captured_status"
assert_eq "blocked is never reloaded" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_contains "blocked is reported" "$captured_output" "is blocked (fskit-provider)"
assert_contains "remedy is mentioned" "$captured_output" "run repair"

# Second tick: reported=true → silent.
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "second tick is silent" "" "$captured_output"
assert_eq "second tick is not reloaded" 0 "$(calls_made "$_tmp/launchctl.log")"

rm -f "$state_dir/local.cloud-mount.iCloud.json"

# ── Section 5: Not-loaded record is reported once (Rule 4b) ───────────────
section 5 "Not-loaded record is reported once"

mkdir -p "$state_dir"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"not-loaded","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"

FAKE_LIVE=""
export FAKE_LIVE FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "not-loaded exits 0" 0 "$captured_status"
assert_contains "not-loaded is reported" "$captured_output" "configured but not loaded"
assert_contains "remedy mentions nucleus-apply" "$captured_output" "nucleus-apply"
assert_eq "not-loaded is never loaded" 0 "$(calls_made "$_tmp/launchctl.log")"

# Second tick: reported → silent.
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "second tick silent" "" "$captured_output"

rm -f "$state_dir/local.cloud-mount.iCloud.json"

# ── Section 6: NixOS crash-loop is stopped ────────────────────────────────
section 6 "NixOS crash-loop is stopped"

mkdir -p "$state_dir"
_now=$(date +%s)
_restarts="$(printf '%s\n' $((_now - 100)) $((_now - 90)) $((_now - 80)) $((_now - 70)) $((_now - 60)) $((_now - 50)) $((_now - 40)) $((_now - 30)) $((_now - 20)) $((_now - 10)) $((_now - 5)) | jq -s '.')"
jq -n --argjson r "$_restarts" --arg boot "$(svc_health_boot_id)" \
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":$r,"runs":3,"lastExit":1}' \
  >"$state_dir/cloud-mount-iCloud.service.json"

FAKE_SYSTEMCTL_STATE="active"
export FAKE_SYSTEMCTL_STATE
FAKE_UNITS="cloud-mount-iCloud.service"
export FAKE_UNITS
FAKE_LIVE=""
export FAKE_LIVE FAKE_STATE
: >"$_tmp/systemctl.log"
run_check_instance "cloud-drive" "nixos-systemctl" "$nixos_entry" "cloud-mount-iCloud.service"
assert_eq "nixos looping exits 0" 0 "$captured_status"
assert_contains "nixos looping is stopped" "$captured_output" "looping"
assert_contains "nixos stop was called" "$(cat "$_tmp/systemctl.log")" "stop"
rm -f "$state_dir/cloud-mount-iCloud.service.json"

# ── Section 7: Prefix expansion — not-loaded reported, unknown skipped ─────
section 7 "Prefix expansion handles per-instance records"

mkdir -p "$state_dir"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"not-loaded","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.OneDrive.json"

# launchctl list returns both; OneDrive is not in FAKE_LIVE → print fails →
# supervisor_enabled returns false → Rule 1 → skip. iCloud is not-loaded.
FAKE_LIVE=""
export FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
: >"$_tmp/launchctl.log"
run_check_prefix "cloud-drive" "macos-launchctl" "$macos_entry"
assert_eq "prefix expansion exits 0" 0 "$captured_status"
assert_contains "not-loaded is reported" "$captured_output" "iCloud configured but not loaded"
assert_not_contains "non-running not reported" "$captured_output" "OneDrive configured but not loaded"

rm -f "$state_dir/local.cloud-mount.iCloud.json" "$state_dir/local.cloud-mount.OneDrive.json"

# ── Section 8: Cleared block allows recovery on next tick ──────────────────
section 8 "Cleared block allows recovery"

mkdir -p "$state_dir"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"blocked","class":"crash-loop","remedy":"supervisor loop","attempts":0,"reportedState":"blocked:crash-loop","boot":$boot,"lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"

# Blocked + already reported → silent.
FAKE_LIVE="local.cloud-mount.iCloud"
export FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "blocked is silent" "" "$captured_output"

# Clear the block → no record → Rule 4 → "not running; starting".
rm -f "$state_dir/local.cloud-mount.iCloud.json"
FAKE_STATE="spawn scheduled"
export FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_contains "cleared block triggers action" "$captured_output" "not running"

# ── Section 9: Stale blocked record (previous boot) is ignored ────────────
section 9 "Stale blocked record from previous boot is ignored"

mkdir -p "$state_dir"
jq -n '{state:"blocked","class":"fskit-provider","remedy":"repair","attempts":0,"reportedState":null,"boot":"old-boot-id-12345","lastSuccess":0,"restarts":[],"runs":0,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"

FAKE_LIVE="local.cloud-mount.iCloud"
export FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
: >"$_tmp/launchctl.log"
: >"$_tmp/booted-out.txt"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "stale block exits 0" 0 "$captured_status"
assert_eq "stale block is not reported" "" "$captured_output"
assert_eq "stale block does not suppress action" 0 "$(calls_made "$_tmp/launchctl.log")"
rm -f "$state_dir/local.cloud-mount.iCloud.json"

# ── Section 10: Empty instance is a no-op ──────────────────────────────────
section 10 "Empty instance is a no-op"

FAKE_LIVE=""
export FAKE_LIVE FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" ""
assert_eq "empty instance exits 0" 0 "$captured_status"
assert_eq "empty instance touches nothing" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "empty instance prints nothing" "" "$captured_output"

finish_tests
