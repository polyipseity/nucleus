#!/usr/bin/env bash
# Tests for src/scripts/services/service-watchdog.sh — the rewritten watchdog
# with canonical instance keys, svc_health_* records, and health-record-driven
# loop detection.
#
# Tests exercise _watchdog_check_instance and _watchdog_check_prefix directly,
# and they drive the real _watchdog_tick themselves: run_tick (defined in
# section 12) invokes it from sections 12, 14, 16 and 17; section 20 does so via
# run_tick_errexit, which carries the daemon's own shell options; and section 22
# runs a tick in a REAL child bash process.  So the tick IS covered here, with
# mocked supervisors and health records.  What is out of scope is a LIVE host
# with a real supervisor — and nothing else covers that either: the Stage 9
# runbook that would is deferred and has never executed, so no artifact should
# be cited in its place.  Each test seeds a svc_health record, configures fake
# launchctl/systemctl via PATH, and asserts the correct supervisor actions and
# notice output.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "service watchdog tests build health records with jq"

WATCHDOG="$REPO_ROOT/src/scripts/services/service-watchdog.sh"
SERVICE_HEALTH="$REPO_ROOT/src/scripts/lib/service-health.sh"

# Pre-set _nuc_prefix and sourcing guards so subshells don't clobber
# the parent shell's notice prefix.
_nuc_prefix="$(basename "$0")"
_nuc_prefix="${_nuc_prefix%.sh}"
case "$_nuc_prefix" in nucleus-*) _nuc_prefix="${_nuc_prefix#nucleus-}" ;; esac
export _nuc_prefix

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin" "$_tmp/home" "$_tmp/repo/src/modules" "$_tmp/repo/src/users/default"
# A registry the loader can assemble. The watchdog's configured-instance
# discovery reads it through svc_configured_mounts, so an absent users root
# would make every prefix tick warn instead of testing what it means to.
printf '{"mounts":[]}\n' >"$_tmp/repo/src/users/default/cloud-drives.json"

# HOME must point into the temp tree so derive_nucleus_user_root resolves
# the state directory inside our temp sandbox.
HOME="$_tmp/home"
export HOME

# Source lib.sh in the parent shell so derive_nucleus_user_root is available.
# Do NOT export _NUCLEUS_LIB_SOURCED — subshells need to source lib.sh fresh
# (they inherit the exported _nuc_prefix which lib.sh preserves).
. "$REPO_ROOT/src/scripts/lib/lib.sh"

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
#   (models an unloadable job). Also drives the supervisor_enabled mock, which
#   models a user-disabled job by returning false for these labels.
# FAKE_LAUNCHCTL_LOG — file where mutating calls are appended.
cat >"$_tmp/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
_booted_out="${FAKE_BOOTED_OUT:-/dev/null}"
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  # FAKE_LIST — labels `launchctl list` enumerates (defaults to FAKE_LIVE).
  # Kept separate because a listed-but-not-loaded job is a real state: notably
  # the not-loaded record a prefix-match service reports for its instances.
  for _label in ${FAKE_LIST:-${FAKE_LIVE:-}}; do printf '4242\t0\t%s\n' "$_label"; done
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
*" show "*)
  # Handle: systemctl show <unit> -p <prop> --value
  case "$*" in
  *NRestarts*) printf '%s' "${FAKE_NRESTARTS:-0}" ;;
  *ExecMainStatus*) printf '%s' "${FAKE_EXIT_CODE:-0}" ;;
  *) printf '0' ;;
  esac
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
# launchctl/systemctl fakes on PATH.  Signatures mirror the production contract:
#   supervisor_enabled   <target> [unit path] [scope]  — false when FAKE_DISABLED or FAKE_ABSENT holds it
#   supervisor_live      <probe output>
#   supervisor_generation <target> [scope]
#   supervisor_last_exit <target> [scope]
#   supervisor_start     <target> [declared] [scope]
#   supervisor_stop      <target> [scope]
#   supervisor_repair    <target> [declared] [scope]
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_enabled() {
  # FAKE_DISABLED models a present-but-disabled job, FAKE_ABSENT a job with no
  # unit at all.  The production contract is "exists AND is allowed to start",
  # so both are not-enabled: they are the two triggers Rule 1's not-loaded
  # writer treats identically.
  local target="$1" label
  label="$(printf '%s' "$target" | sed 's|.*/||')"
  for _a in ${FAKE_ABSENT:-}; do
    if [ "$label" = "$_a" ]; then
      return 1
    fi
  done
  for _d in ${FAKE_DISABLED:-}; do
    if [ "$label" = "$_d" ]; then
      return 1
    fi
  done
  return 0
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_live() {
  local probe_out="$1"
  case "$probe_out" in
  *"state = running"* | *"Active: active"*) return 0 ;;
  esac
  return 1
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_generation() {
  local target="$1" scope="${2:-user}" probe_out
  case "$target" in
  gui/* | system/*)
    probe_out="$(launchctl print "$target" 2>/dev/null || true)"
    printf '%s' "$probe_out" | awk '/runs =/{print $3; exit}'
    ;;
  *) systemctl "$(mock_scope_flag "$scope")" show "$target" -p NRestarts --value 2>/dev/null || printf '0' ;;
  esac
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_last_exit() {
  local target="$1" scope="${2:-user}" probe_out
  case "$target" in
  gui/* | system/*)
    probe_out="$(launchctl print "$target" 2>/dev/null || true)"
    printf '%s' "$probe_out" | awk '/last exit code/{print $5; exit}'
    ;;
  *) systemctl "$(mock_scope_flag "$scope")" show "$target" -p ExecMainStatus --value 2>/dev/null || printf '0' ;;
  esac
}
# mock_scope_flag — the systemctl flag selecting a unit's manager.
# shellcheck disable=SC2329 # reason: invoked by the mock supervisor_generation/supervisor_last_exit, which are themselves invoked indirectly
mock_scope_flag() {
  if [ "${1:-user}" = "system" ]; then printf '%s' "--system"; else printf '%s' "--user"; fi
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_stop() {
  case "$1" in
  gui/* | system/*) launchctl bootout "$1" 2>/dev/null || true ;;
  *.service | *.timer) systemctl stop "$1" 2>/dev/null || true ;;
  *) launchctl bootout "$1" 2>/dev/null || true ;;
  esac
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_start() {
  case "$1" in
  gui/* | system/*) launchctl bootstrap "$1" 2>/dev/null || true ;;
  *.service | *.timer) systemctl start "$1" 2>/dev/null || true ;;
  *) launchctl bootstrap "$1" 2>/dev/null || true ;;
  esac
}
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
supervisor_repair() {
  case "$1" in
  gui/* | system/*)
    launchctl bootout "$1" 2>/dev/null || true
    launchctl bootstrap "$1" 2>/dev/null || true
    ;;
  *.service | *.timer)
    systemctl reset-failed "$1" 2>/dev/null || true
    systemctl start "$1" 2>/dev/null || true
    ;;
  *)
    launchctl bootout "$1" 2>/dev/null || true
    launchctl bootstrap "$1" 2>/dev/null || true
    ;;
  esac
}

# ── Mock lib.sh primitives ─────────────────────────────────────────────────
# shellcheck disable=SC2329,SC2120 # reason: mock functions invoked by eval'd watchdog code
derive_repo_root() { printf '%s' "$_tmp/repo"; }
# shellcheck disable=SC2329 # reason: mock functions invoked by eval'd watchdog code
resolve_nucleus_host() { printf '%s' "${NUCLEUS_HOST:-MacBook}"; }
NUCLEUS_HOST=MacBook

# ── Real launchctl target mapping ──────────────────────────────────────────
# supervisor_resolve_target is a pure formatter shared with nucleus-svc.  The
# mocks above replace the supervisor backends, not this mapping, so the target
# assertions below exercise the production derivation.
# shellcheck source=../../src/scripts/lib/macos-launch-services.sh
. "$REPO_ROOT/src/scripts/lib/macos-launch-services.sh"

# svc-instances.sh provides the configured-instance enumeration the watchdog's
# Rule 1 not-loaded writer needs.  The watchdog sources it at the top level,
# which the awk extraction below skips, so source it here as well.
# shellcheck source=../../src/scripts/lib/svc-instances.sh
. "$REPO_ROOT/src/scripts/lib/svc-instances.sh"

# ── Extract watchdog function definitions (avoid executing _watchdog_main) ──
# The script ends with `_watchdog_main "$@"` which would enter an infinite
# loop.  We extract only the function definitions via awk, then re-source
# service-health.sh to restore any functions clobbered by the eval.
eval "$(awk '/^_watchdog_[a-z_]+\(\)/ || /^supervisor_/ { p = 1 } p { print } p && /^}/ { p = 0; next } /^[^_]/ && !/^#/ && !/^$/ && p == 0 { next }' "$WATCHDOG")"
# shellcheck source=../src/scripts/lib/service-health.sh
# shellcheck disable=SC1091 # reason: relative source path resolves at runtime
# shellcheck source=../src/scripts/lib/service-health.sh
. "$SERVICE_HEALTH"
# Export sourcing guard so subshells don't re-source service-health.sh.
# lib.sh guard is NOT exported — subshells need lib.sh for derive_nucleus_user_root.
export _NUCLEUS_SERVICE_HEALTH_SOURCED

# ── Helpers ─────────────────────────────────────────────────────────────────
state_dir="$(svc_health_state_dir)"

captured_output=""
captured_status=0

# run_check_instance — run _watchdog_check_instance once and capture output.
# Forwards every argument, so a caller can also supply the supervisor unit name
# (arg 5) that the tick resolves from the entry's declared `.service`.
run_check_instance() {
  captured_status=0
  captured_output="$(
    set +euo pipefail
    _watchdog_check_instance "$@" 2>&1
  )" || captured_status=$?
}

# run_check_prefix — run _watchdog_check_prefix once and capture output.
run_check_prefix() {
  captured_status=0
  captured_output="$(
    set +euo pipefail
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

# Export env vars needed by mock launchctl/systemctl subprocesses.
FAKE_LAUNCHCTL_LOG="$_tmp/launchctl.log"
FAKE_BOOTED_OUT="$_tmp/booted-out.txt"
export FAKE_LAUNCHCTL_LOG FAKE_BOOTED_OUT
FAKE_SYSTEMCTL_LOG="$_tmp/systemctl.log"
export FAKE_SYSTEMCTL_LOG

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
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":$r,"generation":null,"lastExit":1}' \
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
  '{state:"blocked","class":"fskit-provider","remedy":"run repair","attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
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

# WHY: the state is DRIVEN, not injected. This section used to fabricate a
# not-loaded record with `jq -n`, which proved only that Rule 4b can read a
# state nothing in production wrote. It now runs the production writer: Rule 1
# with the instance marked configured and the supervisor reporting it disabled.
mkdir -p "$state_dir"
rm -f "$state_dir/local.cloud-mount.iCloud.json"
FAKE_DISABLED="local.cloud-mount.iCloud local.cloud-mount.OneDrive"
FAKE_LIVE=""
export FAKE_DISABLED FAKE_LIVE FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud" \
  "local.cloud-mount.iCloud" true
assert_eq "the writer exits 0" 0 "$captured_status"
assert_contains "the writer reports the instance" "$captured_output" "configured but not loaded"
assert_eq "the writer recorded the not-loaded state" "not-loaded" \
  "$(jq -r '.state' "$state_dir/local.cloud-mount.iCloud.json")"
assert_eq "the writer recorded the notice" "not-loaded" \
  "$(jq -r '.reportedState' "$state_dir/local.cloud-mount.iCloud.json")"
assert_eq "a not-loaded instance is never loaded" 0 "$(calls_made "$_tmp/launchctl.log")"

# A disabled instance the registry does NOT declare stays silent and unrecorded:
# the Windows twin only reports an instance that is configured (arg 6).
rm -f "$state_dir/local.cloud-mount.OneDrive.json"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.OneDrive"
assert_eq "an undeclared disabled instance is silent" "" "$captured_output"
assert_eq "an undeclared disabled instance writes no record" "absent" \
  "$([ -f "$state_dir/local.cloud-mount.OneDrive.json" ] && printf present || printf absent)"

# Second tick, supervisor enabled again: the record alone suppresses the repeat,
# which is what makes the notice once-per-transition rather than once-per-tick.
FAKE_DISABLED=""
export FAKE_DISABLED
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "second tick silent" "" "$captured_output"

rm -f "$state_dir/local.cloud-mount.iCloud.json" "$state_dir/local.cloud-mount.OneDrive.json"

# ── Section 6: NixOS crash-loop is stopped ────────────────────────────────
section 6 "NixOS crash-loop is stopped"

mkdir -p "$state_dir"
_now=$(date +%s)
_restarts="$(printf '%s\n' $((_now - 100)) $((_now - 90)) $((_now - 80)) $((_now - 70)) $((_now - 60)) $((_now - 50)) $((_now - 40)) $((_now - 30)) $((_now - 20)) $((_now - 10)) $((_now - 5)) | jq -s '.')"
jq -n --argjson r "$_restarts" --arg boot "$(svc_health_boot_id)" \
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":$r,"generation":null,"lastExit":1}' \
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
  '{state:"not-loaded","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.iCloud.json"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"stopped","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
  >"$state_dir/local.cloud-mount.OneDrive.json"

# launchctl list enumerates both; OneDrive is not in FAKE_LIVE → print fails →
# the job is not live → Rule 4 revives it. iCloud carries a not-loaded record,
# so it is reported instead of acted on.
FAKE_LIST="local.cloud-mount.iCloud local.cloud-mount.OneDrive"
FAKE_LIVE=""
export FAKE_LIST FAKE_LIVE FAKE_STATE
FAKE_STATE="running"
: >"$_tmp/launchctl.log"
run_check_prefix "cloud-drive" "macos-launchctl" "$macos_entry"
assert_eq "prefix expansion exits 0" 0 "$captured_status"
assert_contains "not-loaded is reported" "$captured_output" "local.cloud-mount.iCloud is configured but not loaded"
assert_not_contains "not-loaded is not claimed for other instances" "$captured_output" "local.cloud-mount.OneDrive is configured but not loaded"

rm -f "$state_dir/local.cloud-mount.iCloud.json" "$state_dir/local.cloud-mount.OneDrive.json"

# ── Section 8: Cleared block allows recovery on next tick ──────────────────
section 8 "Cleared block allows recovery"

mkdir -p "$state_dir"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"blocked","class":"crash-loop","remedy":"supervisor loop","attempts":0,"reportedState":"blocked:crash-loop","boot":$boot,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
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
jq -n '{state:"blocked","class":"fskit-provider","remedy":"repair","attempts":0,"reportedState":null,"boot":"old-boot-id-12345","lastSuccess":0,"restarts":[],"generation":null,"lastExit":0}' \
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

# ── Section 11: Loop protection is uniform across services ────────────────
section 11 "Loop protection is uniform (non-mount service)"

# The loop rule must not depend on the service identity: a daemon with no
# lifecycle block and no mount semantics is blocked by exactly the same code
# path as a cloud mount.
mkdir -p "$state_dir"
_now=$(date +%s)
_restarts="$(printf '%s\n' $((_now - 3300)) $((_now - 3200)) $((_now - 3100)) $((_now - 3000)) $((_now - 2900)) $((_now - 2800)) $((_now - 2700)) $((_now - 2600)) $((_now - 2500)) $((_now - 2400)) $((_now - 120)) | jq -s '.')"
jq -n --argjson r "$_restarts" --arg boot "$(svc_health_boot_id)" \
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":$r,"generation":null,"lastExit":1}' \
  >"$state_dir/local.ollama.json"

ollama_entry='{"type":"macos-launchctl","launchdDomain":"gui"}'
FAKE_LIVE="local.ollama"
FAKE_STATE="running"
FAKE_EXIT_CODE=1
export FAKE_LIVE FAKE_STATE FAKE_EXIT_CODE
: >"$_tmp/launchctl.log"
run_check_instance "ollama" "macos-launchctl" "$ollama_entry" "local.ollama"
assert_eq "non-mount looping exits 0" 0 "$captured_status"
assert_contains "non-mount looping is stopped" "$captured_output" "looping"
assert_contains "non-mount looping is bootout'd" "$(cat "$_tmp/launchctl.log")" "bootout"
rm -f "$state_dir/local.ollama.json"

# ── Section 12: The tick iterates (D5 regression guard) ───────────────────
section 12 "The tick iterates every service on this host"

# D5: svc_keys was assigned inside its own for-loop, so the tick body ran zero
# times and no rule ever executed for any service. This drives the real tick.
count_occurrences() { # <haystack> <needle>
  printf '%s' "$1" | grep -c -F "$2" || true
}

run_tick() {
  captured_status=0
  captured_output="$(
    set +euo pipefail
    _watchdog_tick 2>&1
  )" || captured_status=$?
}

FAKE_LIST="local.cloud-mount.iCloud local.cloud-mount.OneDrive"
FAKE_LIVE=""
export FAKE_LIST FAKE_LIVE
: >"$_tmp/launchctl.log"
run_tick
assert_eq "tick exits 0" 0 "$captured_status"
assert_eq "tick visits every listed instance" 2 "$(count_occurrences "$captured_output" 'is not running; starting')"
assert_eq "tick revives each instance" 2 "$(calls_made "$_tmp/launchctl.log")"

# ── Section 13: Scope selects the domain, .service names the unit ─────────
section 13 "Scope selects the launchd domain and .service names the unit"

# D21: services.schema.json says launchdDomain names only the per-user domain
# and is required exactly when scope is user. A system-scope job is therefore
# addressed as "system/<label>" with no uid; building "gui/<uid>/<label>" for it
# made every macOS system daemon invisible to the watchdog.
system_entry='{"type":"macos-launchctl","scope":"system","service":"local.ollama"}'
FAKE_LIVE=""
FAKE_STATE="spawn scheduled"
export FAKE_LIVE FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "ollama" "macos-launchctl" "$system_entry" "ollama" "local.ollama"
assert_eq "system-scope exits 0" 0 "$captured_status"
assert_contains "system-scope starts in the system domain" "$(cat "$_tmp/launchctl.log")" "system/local.ollama"
assert_not_contains "system-scope never builds a gui target" "$(cat "$_tmp/launchctl.log")" "gui/"

# D22: the health record is keyed by the service key (the BetterDisplay
# heartbeat writes "betterdisplay-heartbeat") while launchd addresses the
# declared label. A target built from the service key named a job that does not
# exist, so the service was never checked and never blocked.
user_entry='{"type":"macos-launchctl","scope":"user","launchdDomain":"gui","service":"local.betterdisplay-heartbeat"}'
mkdir -p "$state_dir"
_now=$(date +%s)
_restarts="$(printf '%s\n' $((_now - 3300)) $((_now - 3200)) $((_now - 3100)) $((_now - 3000)) $((_now - 2900)) $((_now - 2800)) $((_now - 2700)) $((_now - 2600)) $((_now - 2500)) $((_now - 2400)) $((_now - 120)) | jq -s '.')"
jq -n --argjson r "$_restarts" --arg boot "$(svc_health_boot_id)" \
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":$r,"generation":null,"lastExit":1}' \
  >"$state_dir/betterdisplay-heartbeat.json"
FAKE_LIVE="local.betterdisplay-heartbeat"
FAKE_STATE="running"
export FAKE_LIVE FAKE_STATE
: >"$_tmp/launchctl.log"
run_check_instance "betterdisplay-heartbeat" "macos-launchctl" "$user_entry" "betterdisplay-heartbeat" "local.betterdisplay-heartbeat"
assert_contains "service-keyed health record is read" "$captured_output" "looping"
assert_contains "the declared label is unloaded" "$(cat "$_tmp/launchctl.log")" "gui/$(id -u)/local.betterdisplay-heartbeat"
rm -f "$state_dir/betterdisplay-heartbeat.json"

# ── Section 14: The tick resolves the declared unit name (D21/D22) ────────
section 14 "The tick addresses the declared unit name"

cat >"$_tmp/repo/src/modules/services.json" <<'JSON'
{
  "ollama": {
    "displayName": "Ollama",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "scope": "system",
        "service": "local.ollama",
        "unitPath": "/Library/LaunchDaemons/local.ollama.plist"
      }
    }
  }
}
JSON

FAKE_LIST=""
FAKE_LIVE=""
export FAKE_LIST FAKE_LIVE
: >"$_tmp/launchctl.log"
run_tick
assert_eq "tick exits 0" 0 "$captured_status"
assert_contains "tick addresses the system domain" "$(cat "$_tmp/launchctl.log")" "system/local.ollama"
assert_not_contains "tick never addresses the service key" "$(cat "$_tmp/launchctl.log")" "system/ollama"

# ── Section 15: The watchdog writes the restarts it detects (D26) ──────────
section 15 "The tick records supervisor restarts into the health record"

# D26: no production code path wrote the restarts array, so svc_health_is_looping
# could never reach a threshold for any service except the one heartbeat that
# calls record_restart directly — every suite passed only because it seeded the
# array.  The watchdog now folds the supervisor's generation token in on every
# tick, so a restart is detected from the token changing.
_d26_record="$state_dir/local.ollama.json"
restart_len() { jq -r '.restarts | length' "$_d26_record" 2>/dev/null || printf 'missing'; }
generation_of() { jq -r '.generation' "$_d26_record" 2>/dev/null || printf 'missing'; }
success_of() { jq -r '.lastSuccess' "$_d26_record" 2>/dev/null || printf 'missing'; }

ollama_sys='{"type":"macos-launchctl","scope":"system","service":"local.ollama","unitPath":"/Library/LaunchDaemons/local.ollama.plist"}'
FAKE_LIVE="local.ollama"
FAKE_STATE="running"
FAKE_EXIT_CODE=0
export FAKE_LIVE FAKE_STATE FAKE_EXIT_CODE

# (a) First observation: a fresh record adopts the token and records nothing, so
# a cold start is never mistaken for a restart.
rm -f "$_d26_record"
FAKE_RUNS=0
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
assert_eq "first observation records no restart" "0" "$(restart_len)"
assert_eq "first observation adopts the token" "0" "$(generation_of)"

# (b) A token that changed between ticks is one restart, and the array GROWS —
# the writer is reached from production code, not from a seed.
FAKE_RUNS=1
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
assert_eq "a changed token records exactly one restart" "1" "$(restart_len)"
assert_contains "the recorded restart is announced" "$captured_output" "recorded restart"

# (c) An unchanged token means the instance survived the whole tick.
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
assert_eq "an unchanged token records no restart" "1" "$(restart_len)"
if [ "$(success_of)" -gt 0 ]; then
  assert_pass "a surviving tick stamps lastSuccess"
else
  assert_fail "a surviving tick stamps lastSuccess" "lastSuccess=$(success_of)"
fi

# (d) Zero is a legitimate token — systemd's NRestarts reads 0 on a healthy unit
# — so only null/absent may mean unobserved.  A zero sentinel would re-baseline on
# every tick and swallow the service's first restart.
rm -f "$_d26_record"
FAKE_RUNS=0
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
FAKE_RUNS=1
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
assert_eq "a restart after a zero reading is still recorded" "1" "$(restart_len)"

# (e) The token is not necessarily monotonic (a Windows process id, or a run
# time), so it is compared for inequality: `>` would miss a drop entirely.
rm -f "$_d26_record"
jq -n --arg boot "$(svc_health_boot_id)" \
  '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"generation":1234,"lastExit":0}' \
  >"$_d26_record"
FAKE_RUNS=0
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
assert_eq "a drop in the token counts as a restart" "1" "$(restart_len)"
FAKE_RUNS=5678
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
assert_eq "a rise after a drop counts once more" "2" "$(restart_len)"

# (f) End to end: a service with no seeded history reaches the loop threshold from
# observed token changes alone, and is blocked and stopped.
rm -f "$_d26_record"
FAKE_RUNS=0
export FAKE_RUNS
run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
_d26_blocked_tick=""
_d26_tick=1
while [ "$_d26_tick" -le 10 ]; do
  FAKE_RUNS="$_d26_tick"
  export FAKE_RUNS
  : >"$_tmp/launchctl.log"
  run_check_instance "ollama" "macos-launchctl" "$ollama_sys" "local.ollama"
  if printf '%s' "$captured_output" | grep -q "looping"; then
    _d26_blocked_tick="$_d26_tick"
    break
  fi
  _d26_tick=$((_d26_tick + 1))
done
assert_eq "the tick blocks a service it observed looping" "5" "$_d26_blocked_tick"
assert_eq "the observed restarts reached the consecutive threshold" "5" "$(restart_len)"
assert_contains "the looping service is unloaded" "$(cat "$_tmp/launchctl.log")" "bootout"
rm -f "$_d26_record"

# ── Section 16: --scope selects which entries a daemon covers (D33) ────────
section 16 "The requested scope selects which entries are covered"

# D33: each plist passes --scope (the root daemon one value, the per-user agent
# the other), but the flag was absent from the argument case, so it was swallowed
# and every daemon covered both scopes — including the user agent reaching for
# system units through sudo, which cannot prompt inside launchd.
cat >"$_tmp/repo/src/modules/services.json" <<'JSON'
{
  "ollama": {
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "scope": "system",
        "service": "local.ollama",
        "unitPath": "/Library/LaunchDaemons/local.ollama.plist"
      }
    }
  },
  "cloud-drive": {
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "prefixMatch": true,
        "scope": "user",
        "launchdDomain": "gui",
        "service": "local.cloud-mount."
      }
    }
  }
}
JSON

FAKE_LIST="local.cloud-mount.iCloud"
FAKE_LIVE=""
FAKE_STATE="spawn scheduled"
export FAKE_LIST FAKE_LIVE FAKE_STATE

_scope_filter="system"
: >"$_tmp/launchctl.log"
run_tick
assert_eq "system daemon exits 0" 0 "$captured_status"
assert_contains "system daemon covers its own scope" "$(cat "$_tmp/launchctl.log")" "bootstrap system/local.ollama"
assert_not_contains "system daemon never reaches into the user domain" "$(cat "$_tmp/launchctl.log")" "gui/"

_scope_filter="user"
: >"$_tmp/launchctl.log"
run_tick
assert_contains "user agent covers its own scope" "$(cat "$_tmp/launchctl.log")" "bootstrap gui/"
assert_not_contains "user agent never reaches for a system unit" "$(cat "$_tmp/launchctl.log")" "system/local.ollama"

# Without the flag every scope is covered, which is what a manual --oneshot run
# and the pre-existing tests rely on.
_scope_filter=""
: >"$_tmp/launchctl.log"
run_tick
assert_contains "an unflagged run covers the system scope" "$(cat "$_tmp/launchctl.log")" "system/local.ollama"
assert_contains "an unflagged run covers the user scope" "$(cat "$_tmp/launchctl.log")" "gui/"
rm -f "$state_dir/ollama.json"

# ── Section 17: The injected services.json wins over derivation (D34) ──────
section 17 "The injected services.json path is the one read"

# D34: the plists inject NUCLEUS_SERVICES_JSON because the root daemon cannot
# derive the repo — HOME is /var/root and the script lives in the Nix store — so
# derivation produced a path that does not exist and the tick returned no-op.
mkdir -p "$_tmp/injected"
cat >"$_tmp/injected/services.json" <<'JSON'
{
  "injected-probe": {
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "scope": "system",
        "service": "com.example.injected",
        "unitPath": "/Library/LaunchDaemons/com.example.injected.plist"
      }
    }
  }
}
JSON

# The derived registry still lists ollama; if derivation won, the injected unit
# would never be reached.
NUCLEUS_SERVICES_JSON="$_tmp/injected/services.json"
export NUCLEUS_SERVICES_JSON
FAKE_LIST=""
FAKE_LIVE=""
export FAKE_LIST FAKE_LIVE
: >"$_tmp/launchctl.log"
run_tick
assert_eq "injected registry exits 0" 0 "$captured_status"
assert_contains "the injected registry is the one read" "$(cat "$_tmp/launchctl.log")" "system/com.example.injected"
assert_not_contains "the derived registry is not read" "$(cat "$_tmp/launchctl.log")" "local.ollama"
unset NUCLEUS_SERVICES_JSON
rm -f "$state_dir/injected-probe.json"

# ── Section 18: launchd's exit-status shapes parse to integers (D36) ───────
section 18 "launchd exit-status shapes are parsed to an integer"

# D36: `launchctl print` writes "last exit code = 78: EX_CONFIG" and
# "last exit code = (never exited)".  The parser read the raw remainder, so the
# health write received `78:` / `(never` — not a JSON literal — and under set -e
# that aborted the whole tick on the first live job that had never exited.  It
# also made Rule 5's EX_CONFIG repair unreachable, since "78:" is never "78".
_d36_bin="$_tmp/d36bin"
mkdir -p "$_d36_bin"
cat >"$_d36_bin/launchctl" <<'SHAPES'
#!/usr/bin/env bash
printf 'state = running\n\truns = %s\n\tlast exit code = %s\n' "${SHAPE_RUNS:-1}" "${SHAPE_EXIT:-(never exited)}"
SHAPES
chmod +x "$_d36_bin/launchctl"

# parsed_last_exit / parsed_generation run the PRODUCTION backend against those
# shapes in a child shell, so the mocks above stay in force for the rest of the
# suite.
parsed_last_exit() {
  SHAPE_EXIT="$1" PATH="$_d36_bin:$PATH" bash -c '
    . "$1/src/scripts/lib/supervisor-launchd.sh" >/dev/null 2>&1
    supervisor_last_exit target' _ "$REPO_ROOT"
}
parsed_generation() {
  SHAPE_RUNS="$1" PATH="$_d36_bin:$PATH" bash -c '
    . "$1/src/scripts/lib/supervisor-launchd.sh" >/dev/null 2>&1
    supervisor_generation target' _ "$REPO_ROOT"
}

assert_eq "EX_CONFIG parses to its status" "78" "$(parsed_last_exit '78: EX_CONFIG')"
assert_eq "a signal name parses to its number" "9" "$(parsed_last_exit '9: Killed: 9')"
assert_eq "never-exited parses to zero" "0" "$(parsed_last_exit '(never exited)')"
assert_eq "a bare status parses to itself" "1" "$(parsed_last_exit '1')"
assert_eq "the run token is an integer" "4724" "$(parsed_generation '4724')"

# The crash guard: whatever the parser emits must be a literal the record writer
# accepts, or set -e aborts the tick.
_d36_parsed="$(parsed_last_exit '78: EX_CONFIG')"
if printf '%s' "$_d36_parsed" | grep -qE '^-?[0-9]+$'; then
  assert_pass "the parsed status is a JSON number"
else
  assert_fail "the parsed status is a JSON number" "got '$_d36_parsed'"
fi
assert_eq "the parsed status is accepted by the record writer" "0" \
  "$(
    svc_health_set_last_exit "d36-exit-shape" "$_d36_parsed" >/dev/null 2>&1
    printf '%s' "$?"
  )"
_d36_broken="$(parsed_last_exit '(never exited)')"
assert_eq "the never-exited status is accepted by the record writer" "0" \
  "$(
    svc_health_set_last_exit "d36-never-exited" "$_d36_broken" >/dev/null 2>&1
    printf '%s' "$?"
  )"
rm -f "$state_dir/d36-exit-shape.json" "$state_dir/d36-never-exited.json"

# ── Section 19: a self-recording daemon is covered by the uniform rule ─────
section 19 "A self-recording daemon is blocked by the uniform loop rule"

# betterdisplay-heartbeat has no supervisor counter to fold in: the daemon
# records each relaunch itself through svc_health_record_restart
# (macos-heartbeat-betterdisplay.sh:50).  Loop protection must therefore reach
# it through exactly the same predicate and the same Rule 3 branch as a cloud
# mount — nothing about this service is special-cased.  Its health record is
# keyed by the service key while launchd addresses the declared label, so the
# check is called with the record key and the unit separately: that split is the
# asymmetry the watchdog resolves internally, and a check that conflated the two
# would read an empty record and never detect the loop.
bd_health_key="betterdisplay-heartbeat"
bd_label="local.betterdisplay-heartbeat"
bd_record="$state_dir/$bd_health_key.json"
bd_entry='{"type":"macos-launchctl","scope":"user","launchdDomain":"gui","service":"local.betterdisplay-heartbeat","unitPath":"~/Library/LaunchAgents/local.betterdisplay-heartbeat.plist"}'

bd_relaunch() { # <count> — the daemon's own recording call, repeated
  local _n=0
  while [ "$_n" -lt "$1" ]; do
    svc_health_record_restart "$bd_health_key" "relaunch" >/dev/null 2>&1
    _n=$((_n + 1))
  done
}
bd_check() { run_check_instance "$bd_health_key" "macos-launchctl" "$bd_entry" "$bd_health_key" "$bd_label"; }
bd_restarts() { jq -r '.restarts | length' "$bd_record" 2>/dev/null || printf 'missing'; }
bd_field() { jq -r "$1" "$bd_record" 2>/dev/null || printf 'missing'; }
bd_looping() { if svc_health_is_looping "$bd_health_key"; then printf 'yes'; else printf 'no'; fi; }

FAKE_LIVE="local.betterdisplay-heartbeat"
FAKE_STATE="running"
FAKE_EXIT_CODE=0
FAKE_RUNS=1
export FAKE_LIVE FAKE_STATE FAKE_EXIT_CODE FAKE_RUNS

# (a) Below the bound the daemon's own relaunches are not yet a loop, and the
#     watchdog leaves it running rather than blocking a working service.
rm -f "$bd_record"
bd_relaunch 4
assert_eq "the daemon recorded its own relaunches" 4 "$(bd_restarts)"
assert_eq "the daemon never recorded a success" 0 "$(bd_field '.lastSuccess')"
assert_eq "below the bound the predicate does not trip" "no" "$(bd_looping)"
: >"$_tmp/launchctl.log"
bd_check
assert_eq "a sub-threshold daemon exits 0" 0 "$captured_status"
assert_eq "a sub-threshold daemon is not stopped" 0 "$(calls_made "$_tmp/launchctl.log")"
assert_eq "a sub-threshold daemon is not blocked" "null" "$(bd_field '.class')"

# (b) One more relaunch crosses the consecutive bound on its own: the only input
#     is the daemon's self-recording, with no supervisor counter involved.
bd_relaunch 1
assert_eq "the daemon recorded five relaunches" 5 "$(bd_restarts)"
assert_eq "the uniform predicate trips on the daemon's own restarts" "yes" "$(bd_looping)"

# (c) The watchdog acts on it.  The supervisor's run token is unchanged between
#     ticks, so the tick records a success — which clears the consecutive count
#     but not the hourly one.  The hourly bound is therefore what keeps the loop
#     detected here, and the block must still land.
bd_relaunch 5
assert_eq "the daemon reached the hourly bound" 10 "$(bd_restarts)"
: >"$_tmp/launchctl.log"
bd_check
assert_contains "the self-looping daemon is blocked" "$captured_output" "looping"
assert_contains "the self-looping daemon is stopped" "$(cat "$_tmp/launchctl.log")" "bootout"
assert_contains "the block targets the declared unit, not the record key" \
  "$(cat "$_tmp/launchctl.log")" "$bd_label"
assert_eq "the block uses the generic crash-loop class" "crash-loop" "$(bd_field '.class')"
assert_eq "the block is written to the daemon's own record" "blocked" "$(bd_field '.state')"
assert_eq "the restarts counted are the daemon's own" 10 "$(bd_restarts)"
rm -f "$bd_record"

# ── Section 20: A corrupt record must not abort the tick (F1) ─────────────
section 20 "A corrupt record does not abort the tick"

# run_tick_errexit — as run_tick, but with the daemon's own shell options.
# WHY: the daemon runs `set -euo pipefail`, and this abort happens ONLY under
# errexit.  The ordinary runner deliberately disables it so an assertion failure
# cannot kill the suite — which is exactly why the suite could not see this class
# before, even though the class had already fired once in production.
run_tick_errexit() {
  captured_status=0
  captured_output="$(
    set -euo pipefail
    _watchdog_tick 2>&1
  )" || captured_status=$?
}

# Two instances with the corrupt one first in the enumeration: the tick must
# survive it and still check the one behind it.  Before the fix the tick died at
# the corrupt record, so every service later in the list was silently unchecked.
mkdir -p "$state_dir"
FAKE_LIST="local.cloud-mount.aaa-broken local.cloud-mount.bbb-healthy"
FAKE_LIVE=""
FAKE_DISABLED=""
FAKE_ABSENT=""
export FAKE_LIST FAKE_LIVE FAKE_DISABLED FAKE_ABSENT FAKE_STATE
rm -f "$state_dir/local.cloud-mount.aaa-broken.json" "$state_dir/local.cloud-mount.bbb-healthy.json"
# A record that exists but is not JSON: the shape an interrupted write, a foreign
# writer, or a one-off migration can leave behind.
printf '{ this is not json' >"$state_dir/local.cloud-mount.aaa-broken.json"
: >"$_tmp/launchctl.log"
run_tick_errexit
assert_eq "the tick survives a corrupt record" 0 "$captured_status"
assert_contains "the corruption is reported on read" "$captured_output" "unreadable health record"
assert_contains "the service behind the corrupt record is still checked" "$captured_output" \
  "local.cloud-mount.bbb-healthy is not running"

# Direct guard assertion: the accessor is what makes a corrupt record survivable
# under errexit, so call it plainly — exactly as the tick does — and require it to
# report and return success instead of propagating jq's failure.
_direct_status=0
_direct_out="$(
  set -euo pipefail
  _watchdog_health_field "local.cloud-mount.aaa-broken" "state" 2>&1
)" || _direct_status=$?
assert_eq "the record accessor survives a corrupt record" 0 "$_direct_status"
assert_contains "the accessor reports the corruption" "$_direct_out" "unreadable health record"
rm -f "$state_dir/local.cloud-mount.aaa-broken.json"

# Control: with a valid record the same tick still exits 0 and checks both, so
# the abort above is caused by the corruption and not by the fixture.
rm -f "$state_dir/local.cloud-mount.aaa-broken.json"
svc_health_init "local.cloud-mount.aaa-broken"
run_tick_errexit
assert_eq "a valid record still exits 0" 0 "$captured_status"
assert_not_contains "a valid record reports no corruption" "$captured_output" "unreadable health record"
assert_contains "every service is checked when records are valid" "$captured_output" \
  "local.cloud-mount.aaa-broken is not running"

rm -f "$state_dir/local.cloud-mount.aaa-broken.json" "$state_dir/local.cloud-mount.bbb-healthy.json"

# ── Section 21: A configured-but-absent instance is reported (F2) ─────────
section 21 "Configured but absent instances are reported"

# The POSIX twin of the Windows path: an instance the user registry declares is
# expected to run even while no unit exists for it, so discovery reads the
# registry and the watchdog reports the gap once instead of starting nothing.
# svc_configured_mounts reads the invoking user (SUDO_USER here, as it is for a
# sudo-run command), so declare the mount for that name.
mkdir -p "$_tmp/repo/src/users/testuser"
printf '{"mounts":[{"id":"iCloud","remoteName":"icloud","localPath":"clouds/iCloud"}]}\n' \
  >"$_tmp/repo/src/users/testuser/cloud-drives.json"
SUDO_USER=testuser
export SUDO_USER

FAKE_LIST=""
FAKE_LIVE=""
FAKE_DISABLED=""
# Declared but never provisioned: no unit exists for the mount.  This is the
# real-world F2 shape (a registry entry with no matching job), so model absence
# rather than a job someone switched off.
FAKE_ABSENT="local.cloud-mount.iCloud"
export FAKE_LIST FAKE_LIVE FAKE_DISABLED FAKE_ABSENT FAKE_STATE
rm -f "$state_dir/local.cloud-mount.iCloud.json"
: >"$_tmp/launchctl.log"
run_check_prefix "cloud-drive" "macos-launchctl" "$macos_entry"
assert_eq "configured-instance discovery exits 0" 0 "$captured_status"
assert_contains "the declared mount is reported" "$captured_output" \
  "local.cloud-mount.iCloud is configured but not loaded"
assert_eq "the declared mount is recorded as not-loaded" "not-loaded" \
  "$(jq -r '.state' "$state_dir/local.cloud-mount.iCloud.json")"
assert_eq "the declared mount is never loaded" 0 "$(calls_made "$_tmp/launchctl.log")"

# Nothing declared must mean nothing reported — the report follows the registry,
# not the label prefix.
rm -f "$state_dir/local.cloud-mount.iCloud.json"
printf '{"mounts":[]}\n' >"$_tmp/repo/src/users/testuser/cloud-drives.json"
run_check_prefix "cloud-drive" "macos-launchctl" "$macos_entry"
assert_eq "a registry with no mounts is silent" "" "$captured_output"
FAKE_ABSENT=""
export FAKE_ABSENT

# A declared mount the supervisor DOES have live is not reported: it is being
# run, so it is not missing.
printf '{"mounts":[{"id":"iCloud","remoteName":"icloud","localPath":"clouds/iCloud"}]}\n' \
  >"$_tmp/repo/src/users/testuser/cloud-drives.json"
FAKE_LIST="local.cloud-mount.iCloud"
FAKE_LIVE="local.cloud-mount.iCloud"
FAKE_STATE="running"
export FAKE_LIST FAKE_LIVE FAKE_STATE
rm -f "$state_dir/local.cloud-mount.iCloud.json"
run_check_prefix "cloud-drive" "macos-launchctl" "$macos_entry"
assert_not_contains "a live declared mount is not reported" "$captured_output" "configured but not loaded"

unset SUDO_USER
rm -rf "$_tmp/repo/src/users/testuser"
rm -f "$state_dir/local.cloud-mount.iCloud.json"

# ── Section 22: The real subprocess abort (F1) ─────────────────────────────
section 22 "A corrupt record does not abort a real subprocess tick"

# WHY this section exists even though §20 tests the same fixture: §20 calls
#   _watchdog_tick IN-PROCESS, inside a command substitution that sits in an
#   `||` list.  Bash suppresses errexit for a command in that position, so §20
#   passes on the PRE-FIX code and cannot see the production abort at all — a
#   test that cannot fail is not coverage.  This section runs the same real
#   libraries in a REAL child bash process, where `set -euo pipefail` is
#   genuinely live: the same condition the KeepAlive daemon runs under.
#   The mocks this suite defines are shell functions, and `export -f` hands them
#   to the child unchanged, so the only difference from §20 is the PROCESS
#   BOUNDARY (and therefore errexit) — not the fixture, and not the supervisor.
F1_DRIVER="$_tmp/f1-subprocess-tick.sh"
cat >"$F1_DRIVER" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
# The parent exports the service-health guard so its own subshells skip
# re-sourcing; this is a fresh shell and must source everything itself.
unset _NUCLEUS_LIB_SOURCED _NUCLEUS_SERVICE_HEALTH_SOURCED
# WHY two roots: the LIBRARIES are sourced from the real checkout, while
#   NUCLEUS_REPO_ROOT points lib.sh's own derive_repo_root() at the sandbox stub
#   the suite populates — so registry reads stay hermetic without mocking the
#   resolver.
. "$F1_LIB_ROOT/src/scripts/lib/lib.sh"
. "$F1_LIB_ROOT/src/scripts/lib/macos-launch-services.sh"
. "$F1_LIB_ROOT/src/scripts/lib/svc-instances.sh"
# The watchdog ends with `_watchdog_main "$@"`, which would loop forever, so
# extract function definitions only — the same extraction the suite performs.
eval "$(awk '/^_watchdog_[a-z_]+\(\)/ || /^supervisor_/ { p = 1 } p { print } p && /^}/ { p = 0; next } /^[^_]/ && !/^#/ && !/^$/ && p == 0 { next }' "$F1_WATCHDOG")"
# The CLI parser is part of the skipped top level, so its two globals must be
# initialised here: _watchdog_scope_selected reads $_scope_filter under `set -u`.
_scope_filter=""
_oneshot=false
. "$F1_SERVICE_HEALTH"
_watchdog_tick
DRIVER

# run_subprocess_tick — run one tick in a child bash process and capture its
# exit status and combined output.  The `||` list here suppresses errexit in
# THIS shell only; the child is a separate process running its own `set -e`.
run_subprocess_tick() {
  captured_status=0
  captured_output="$(
    export -f supervisor_enabled supervisor_live supervisor_generation \
      supervisor_last_exit supervisor_stop supervisor_start supervisor_repair \
      mock_scope_flag
    F1_LIB_ROOT="$REPO_ROOT" \
      F1_WATCHDOG="$WATCHDOG" \
      F1_SERVICE_HEALTH="$SERVICE_HEALTH" \
      NUCLEUS_REPO_ROOT="$_tmp/repo" \
      NUCLEUS_HOST=MacBook \
      bash "$F1_DRIVER" 2>&1
  )" || captured_status=$?
}

# Same two records as §20 — corrupt first, healthy second — so the only
# variable changed is the process boundary.
FAKE_LIST="local.cloud-mount.aaa-broken local.cloud-mount.bbb-healthy"
FAKE_LIVE=""
FAKE_DISABLED=""
FAKE_ABSENT=""
FAKE_STATE=""
export FAKE_LIST FAKE_LIVE FAKE_DISABLED FAKE_ABSENT FAKE_STATE
rm -f "$state_dir/local.cloud-mount.aaa-broken.json" "$state_dir/local.cloud-mount.bbb-healthy.json"
printf '{ this is not json' >"$state_dir/local.cloud-mount.aaa-broken.json"
: >"$_tmp/launchctl.log"

run_subprocess_tick
assert_eq "the real subprocess tick survives a corrupt record" 0 "$captured_status"
assert_contains "the real subprocess reports the corrupt record" "$captured_output" \
  "unreadable health record"
# THE regression assertion: pre-fix the tick died at the corrupt record, so
# every instance AFTER it was left unchecked for as long as the record stayed
# corrupt.
assert_contains "the instance after the corrupt record is still checked" "$captured_output" \
  "local.cloud-mount.bbb-healthy is not running"

# Control: with no corruption the same subprocess reaches both instances, so a
# silent child cannot make the assertions above pass for the wrong reason.
rm -f "$state_dir/local.cloud-mount.aaa-broken.json"
svc_health_init "local.cloud-mount.aaa-broken"
run_subprocess_tick
assert_eq "the real subprocess tick exits 0 without corruption" 0 "$captured_status"
assert_contains "both instances are checked when records are valid" "$captured_output" \
  "local.cloud-mount.aaa-broken is not running"
assert_contains "the second instance is reached without corruption" "$captured_output" \
  "local.cloud-mount.bbb-healthy is not running"

rm -f "$state_dir/local.cloud-mount.aaa-broken.json" "$state_dir/local.cloud-mount.bbb-healthy.json" "$F1_DRIVER"

# ── Section 23: the repair call is bounded by the declared policy ────────
section 23 "A repair call is bounded by the declared watchdogRepairTimeoutSeconds"

# A repair (live + last exit 78) is a bootout+bootstrap, and a dead macFUSE/FSKit
# volume blocks inside the kernel.  Unbounded, ONE hung repair stalls the whole
# tick and every instance after it goes unchecked — which is why the value
# bounding a single repair call is declared in services.json and read per tick.
# These checks pin that the value is ENFORCED, and that neither an absent nor a
# malformed value can make the call unbounded.  All three are behavioural: the
# watchdog ends with `_watchdog_main "$@"`, so it cannot be sourced in-process
# and there is no unit-level way to call the reader without re-stating it.
_repair_marker="$_tmp/repair-invoked.txt"
_orig_repair="$(declare -f supervisor_repair)"
# shellcheck disable=SC2329 # reason: invoked by eval'd watchdog code through svc_run_bounded in a subshell
supervisor_repair() {
  printf 'started\n' >>"$_repair_marker"
  # WHY the redirect: this sleep is deliberately longer than the declared bound,
  #   and a background process still holding the captured stdout pipe would keep
  #   the command substitution open until it exited — making the elapsed-time
  #   check below measure the sleep instead of the bound.
  sleep 5 >/dev/null 2>&1
  printf 'completed\n' >>"$_repair_marker"
}

# repair_policy — write a one-key registry carrying $1, or none when ABSENT.
repair_policy() {
  mkdir -p "$_tmp/repair-policy"
  if [ "$1" = "ABSENT" ]; then
    printf '{"cloud-drive":{"lifecycle":{"watchdogTickSeconds":300}}}\n' >"$_tmp/repair-policy/services.json"
  else
    printf '{"cloud-drive":{"lifecycle":{"watchdogRepairTimeoutSeconds":%s}}}\n' "$1" >"$_tmp/repair-policy/services.json"
  fi
}

seed_repair_record() {
  jq -n --arg boot "$(svc_health_boot_id)" \
    '{state:"running","class":null,"remedy":null,"attempts":0,"reportedState":null,"boot":$boot,"lastSuccess":0,"restarts":[],"generation":null,"lastExit":78}' \
    >"$state_dir/local.cloud-mount.iCloud.json"
}

# repair_started / repair_completed — grep -q, so a missing marker reads as absent
# WITHOUT the `grep -c` trap: grep -c prints 0 AND returns 1 on no match, so it would
# have to be guarded with `|| printf 0`, emitting `0\n0` and silently defeating the
# comparison.  Distinct markers, because "the repair started" and "the repair ran to
# completion" are exactly what a bound changes.
repair_started() {
  [ -f "$_repair_marker" ] && grep -q '^started$' "$_repair_marker"
}
repair_completed() {
  [ -f "$_repair_marker" ] && grep -q '^completed$' "$_repair_marker"
}

FAKE_LIVE="local.cloud-mount.iCloud"
FAKE_STATE="running"
FAKE_EXIT_CODE=78
export FAKE_LIVE FAKE_STATE FAKE_EXIT_CODE

# (1) The declared bound is enforced.
repair_policy 1
NUCLEUS_SERVICES_JSON="$_tmp/repair-policy/services.json"
export NUCLEUS_SERVICES_JSON
rm -f "$_repair_marker"
seed_repair_record
: >"$_tmp/launchctl.log"
_started="$(date +%s)"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
_elapsed=$(($(date +%s) - _started))
assert_eq "the repair path exits 0" 0 "$captured_status"
# CONTROL: the hanging repair must be the code that ran, or the timing measures nothing.
if repair_started; then
  assert_pass "the hanging repair is the code under the bound"
else
  assert_fail "the hanging repair is the code under the bound" "the repair was never invoked"
fi
assert_contains "a repair outliving the declared bound is abandoned" "$captured_output" "timed out after 1s"
if repair_completed; then
  assert_fail "a repair outliving the declared bound never completes" \
    "the repair ran to completion, so the declared 1s did not bound it"
else
  assert_pass "a repair outliving the declared bound never completes"
fi
if [ "$_elapsed" -lt 5 ]; then
  assert_pass "the bound returns before the repair would have finished"
else
  assert_fail "the bound returns before the repair would have finished" \
    "took ${_elapsed}s; the repair sleeps 5s, so the call was not bounded"
fi

# (2) An ABSENT value still yields a positive bound: the same repair is allowed to
# finish instead of being abandoned instantly (a zero/empty bound would report a
# timeout here, and an unbounded call would hang the tick for good).
repair_policy ABSENT
rm -f "$_repair_marker"
seed_repair_record
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
assert_eq "an absent bound still exits 0" 0 "$captured_status"
if repair_started; then
  assert_pass "the hanging repair ran under the absent-key default"
else
  assert_fail "the hanging repair ran under the absent-key default" "the repair was never invoked"
fi
# The repair sleeps 5s: that it RAN TO COMPLETION is what proves the absent-key
# fallback is a positive bound.  A zero/empty fallback would abandon the call at
# once, and no fallback at all would leave it unbounded.
if repair_completed; then
  assert_pass "an absent value yields a positive bound, not zero"
else
  assert_fail "an absent value yields a positive bound, not zero" \
    "the repair was abandoned, so the fallback is not a usable bound"
fi
assert_not_contains "an absent bound is not reported as a timeout" "$captured_output" "timed out"

# (3) A MALFORMED value must not hang: svc_run_bounded cannot evaluate the bound
# (`$((bound * 5))` on a non-numeric string is an unbound-variable error under
# set -u), so the call is refused BEFORE it is backgrounded and the tick reports
# it instead of dying.
repair_policy '"abc"'
rm -f "$_repair_marker"
seed_repair_record
_started="$(date +%s)"
run_check_instance "cloud-drive" "macos-launchctl" "$macos_entry" "local.cloud-mount.iCloud"
_elapsed=$(($(date +%s) - _started))
assert_eq "a malformed bound does not abort the tick" 0 "$captured_status"
if repair_completed; then
  assert_fail "a malformed bound never lets the repair run to completion" \
    "the repair completed, so a non-numeric bound did not bound it"
else
  assert_pass "a malformed bound never lets the repair run to completion"
fi
# The warning differs by CONTEXT, and both are correct: run_check_instance runs the
# tick under `set +euo pipefail` (nounset OFF), so `$((abc * 5))` evaluates the stray
# name to 0 and the call is abandoned immediately; with nounset ON — the daemon's own
# environment — the evaluation itself fails and svc_run_bounded refuses the call
# before backgrounding it.  Either way the tick survives and the failure is reported;
# the regression this pins is the SILENT one.
if printf '%s' "$captured_output" | grep -qE 'timed out after|could not repair'; then
  assert_pass "a malformed bound is reported, not swallowed"
else
  assert_fail "a malformed bound is reported, not swallowed" "no repair warning in: $captured_output"
fi
if [ "$_elapsed" -lt 5 ]; then
  assert_pass "a malformed bound does not hang the tick"
else
  assert_fail "a malformed bound does not hang the tick" "took ${_elapsed}s"
fi

eval "$_orig_repair"
unset NUCLEUS_SERVICES_JSON FAKE_EXIT_CODE
FAKE_LIVE=""
FAKE_STATE=""
export FAKE_LIVE FAKE_STATE
rm -f "$_repair_marker" "$state_dir/local.cloud-mount.iCloud.json"

# ── Section 24: an unknown supervisor type is skipped, not fatal ───────────
section 24 "An unknown supervisor type is skipped instead of aborting it"

# WHY a REAL child process (F2-a): `run_check_prefix` deliberately wraps its
#   call in `set +euo pipefail`, so an unassigned variable is NOT an error
#   there — any test built on that helper passes on pre-fix code and cannot see
#   the production abort. That is the same "test that cannot fail" trap §22
#   documents, one level down.
# F2-a: _watchdog_check_prefix's `case` had NO default arm while live_instances
#   was a bare `local`. An unassigned local IS unbound under `set -u` (measured
#   rc=127), so an unmatched type raised "unbound variable" while expanding
#   `<<<"$live_instances"` and killed the WHOLE tick instead of skipping one
#   entry. Its sibling _watchdog_check_instance has always had `*) return 0`.
#   `windows-schtask` is the exact arm that was deleted.
F2A_DRIVER="$_tmp/f2a-unknown-type.sh"
cat >"$F2A_DRIVER" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
unset _NUCLEUS_LIB_SOURCED _NUCLEUS_SERVICE_HEALTH_SOURCED
. "$F2A_LIB_ROOT/src/scripts/lib/lib.sh"
. "$F2A_LIB_ROOT/src/scripts/lib/macos-launch-services.sh"
. "$F2A_LIB_ROOT/src/scripts/lib/svc-instances.sh"
eval "$(awk '/^_watchdog_[a-z_]+\(\)/ || /^supervisor_/ { p = 1 } p { print } p && /^}/ { p = 0; next } /^[^_]/ && !/^#/ && !/^$/ && p == 0 { next }' "$F2A_WATCHDOG")"
_scope_filter=""
# The marker proves the harness REACHED the call: without it, an extraction
# that silently produced no function would leave the status at 0 and every
# assertion below would pass for the wrong reason.
printf '%s\n' 'F2A-CALLED' >&2
_watchdog_check_prefix "cloud-drive" "windows-schtask" "$F2A_ENTRY"
DRIVER

run_unknown_type() {
  captured_status=0
  captured_output="$(
    export -f supervisor_enabled supervisor_live supervisor_generation \
      supervisor_last_exit supervisor_stop supervisor_start supervisor_repair \
      mock_scope_flag
    F2A_LIB_ROOT="$REPO_ROOT" F2A_WATCHDOG="$WATCHDOG" F2A_ENTRY="$macos_entry" \
      NUCLEUS_REPO_ROOT="$_tmp/repo" NUCLEUS_HOST=MacBook \
      bash "$F2A_DRIVER" 2>&1
  )" || captured_status=$?
}

run_unknown_type
case "$captured_output" in
*"F2A-CALLED"*) _f2a_reached=1 ;;
*) _f2a_reached=0 ;;
esac
case "$captured_output" in
*"unbound variable"*) _f2a_unbound=1 ;;
*) _f2a_unbound=0 ;;
esac
assert_eq "control: the child harness reaches the call" 1 "$_f2a_reached"
assert_eq "an unknown supervisor type exits 0" 0 "$captured_status"
assert_eq "an unknown supervisor type does not raise an unbound variable" 0 "$_f2a_unbound"
rm -f "$F2A_DRIVER"

finish_tests
