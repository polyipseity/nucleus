#!/usr/bin/env bash
# Tests for live target enumeration, the pre-rebuild enable gate, and the
# post-rebuild repair of cleared gates. The fake supervisors report only the
# labels and units a case seeds, so no case reaches a real service manager.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "target tests build a fixture registry with jq"

TARGETS_LIB="$REPO_ROOT/src/scripts/lib/service-targets.sh"
APPLY_SH="${APPLY_SH:-$REPO_ROOT/src/scripts/apply.sh}"
ENABLE_SH="${ENABLE_SH:-$REPO_ROOT/src/scripts/services/managed-services-enable.sh}"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"
REGISTRY="$_tmp/services.json"
FAKE_SVC="$_tmp/bin/fake-svc"
FAKE_SVC_LOG="$_tmp/fake-svc.log"
export FAKE_SVC_LOG

_schema="$(jq -c '."$schema"' "$REPO_ROOT/src/modules/services.json")"
cat >"$REGISTRY" <<JSON
{
  "\$schema": $_schema,
  "plain-macos": {
    "displayName": "Plain macOS service",
    "hosts": {
      "MacBook": { "type": "macos-launchctl", "service": "local.plain-macos", "scope": "user", "launchdDomain": "gui" },
      "NixOS": { "type": "omitted" },
      "Windows": { "type": "omitted" }
    }
  },
  "plain-nixos": {
    "displayName": "Plain NixOS service",
    "hosts": {
      "MacBook": { "type": "omitted" },
      "NixOS": { "type": "nixos-systemctl", "service": "plain-nixos.service", "scope": "system" },
      "Windows": { "type": "omitted" }
    }
  },
  "skipped": {
    "displayName": "Omitted on both hosts",
    "hosts": {
      "MacBook": { "type": "omitted" },
      "NixOS": { "type": "omitted" },
      "Windows": { "type": "omitted" }
    }
  },
  "prefixed": {
    "displayName": "Prefixed services",
    "hosts": {
      "MacBook": { "type": "macos-launchctl", "prefixMatch": true, "service": "local.prefix.", "scope": "user", "launchdDomain": "gui" },
      "NixOS": { "type": "nixos-systemctl", "prefixMatch": true, "service": "prefix-", "scope": "system" },
      "Windows": { "type": "omitted" }
    }
  }
}
JSON

cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  for label in ${FAKE_LIVE_LABELS:-}; do printf '4242\t0\t%s\n' "$label"; done
  exit 0
  ;;
print)
  if [ -n "${FAKE_PROBE_EXIT:-}" ]; then
    printf '%s\n' "${FAKE_PROBE_MESSAGE:-probe failed}" >&2
    exit "$FAKE_PROBE_EXIT"
  fi
  for label in ${FAKE_LOADED_LABELS:-}; do
    case "${2:-}" in
    *"/$label") exit 0 ;;
    esac
  done
  printf 'Could not find service "%s"\n' "${2:-}" >&2
  exit 113
  ;;
esac
exit 1
FAKE_LAUNCHCTL

cat >"$_tmp/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
  list-units)
    for unit in ${FAKE_LIVE_UNITS:-}; do printf '%s loaded active running fake\n' "$unit"; done
    exit 0
    ;;
  esac
done

_unit="${*: -1}"
case "${2:-}" in
is-enabled)
  for unit in ${FAKE_ENABLED_UNITS:-}; do
    [ "$unit" = "$_unit" ] || continue
    printf 'enabled\n'
    exit 0
  done
  printf 'not-found\n'
  exit 0
  ;;
show)
  if [ -n "${FAKE_SYSTEMCTL_PROBE_EXIT:-}" ]; then
    printf '%s\n' "${FAKE_SYSTEMCTL_PROBE_MESSAGE:-load state probe failed}" >&2
    exit "$FAKE_SYSTEMCTL_PROBE_EXIT"
  fi
  for unit in ${FAKE_LIVE_UNITS:-}; do
    [ "$unit" = "$_unit" ] || continue
    printf 'loaded\n'
    exit 0
  done
  printf 'not-found\n'
  exit 0
  ;;
start)
  exit 0
  ;;
esac
exit 1
FAKE_SYSTEMCTL

cat >"$FAKE_SVC" <<'FAKE_SVC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SVC_LOG"
if [ "${1:-}" = enable ] && [ "${2:-}" = "${FAKE_SVC_FAIL_TARGET:-}" ]; then
  printf '%s\n' "fake enable failed for $2" >&2
  exit 1
fi
exit 0
FAKE_SVC
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/systemctl" "$FAKE_SVC"

assert_eq() { # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3" "expected '$1', got '$2'"
  fi
}

assert_absent() { # <haystack> <needle> <name>
  case "$1" in
  *"$2"*) assert_fail "$3" "unexpected '$2' in: $1" ;;
  *) assert_pass "$3" ;;
  esac
}

assert_no_start() { # <log> <name>
  # The fake svc script logs one command per line, starting with the verb.
  if printf '%s\n' "$1" | grep -q '^start '; then
    assert_fail "$2" "unexpected start call in: $1"
  else
    assert_pass "$2"
  fi
}

assert_contains() { # <haystack> <needle> <name>
  case "$1" in
  *"$2"*) assert_pass "$3" ;;
  *) assert_fail "$3" "missing '$2' in: $1" ;;
  esac
}

fake_env() { # <command> [args...]
  env PATH="$_tmp/bin:$PATH" \
    FAKE_LIVE_LABELS="${FAKE_LIVE_LABELS:-}" \
    FAKE_LOADED_LABELS="${FAKE_LOADED_LABELS:-}" \
    FAKE_LIVE_UNITS="${FAKE_LIVE_UNITS:-}" \
    FAKE_ENABLED_UNITS="${FAKE_ENABLED_UNITS:-}" \
    FAKE_PROBE_EXIT="${FAKE_PROBE_EXIT:-}" \
    FAKE_PROBE_MESSAGE="${FAKE_PROBE_MESSAGE:-}" \
    FAKE_SYSTEMCTL_PROBE_EXIT="${FAKE_SYSTEMCTL_PROBE_EXIT:-}" \
    FAKE_SYSTEMCTL_PROBE_MESSAGE="${FAKE_SYSTEMCTL_PROBE_MESSAGE:-}" \
    FAKE_SVC_FAIL_TARGET="${FAKE_SVC_FAIL_TARGET:-}" \
    FAKE_SVC_LOG="$FAKE_SVC_LOG" \
    "$@"
}

run_targets() { # <host>
  # shellcheck disable=SC2016 # reason: the child shell expands the positional arguments at runtime
  fake_env bash -c 'set -euo pipefail; . "$1"; service_targets_for_host "$2" "$3"' \
    _ "$TARGETS_LIB" "$REGISTRY" "$1"
}

run_enable() { # <host>
  fake_env bash "$ENABLE_SH" "$REGISTRY" "$1" "$FAKE_SVC"
}

section 1 "Registry enumeration reports live targets only"

FAKE_LIVE_LABELS=""
_macbook_empty_prefix="$(run_targets MacBook)" || true
assert_eq "plain-macos" "$_macbook_empty_prefix" \
  "a prefix row with no live instance adds no target"
assert_absent "$_macbook_empty_prefix" "prefixed" "the pseudo prefix key is not a target"
assert_absent "$_macbook_empty_prefix" "plain-nixos" "an omitted host entry is not a target"

FAKE_LIVE_LABELS="local.prefix.one local.prefix.one"
_macbook_targets="$(run_targets MacBook)" || true
assert_eq $'plain-macos\nlocal.prefix.one' "$_macbook_targets" \
  "one live prefix instance is listed once"
assert_eq "1" "$(printf '%s\n' "$_macbook_targets" | grep -cx 'local.prefix.one')" \
  "a duplicate supervisor row is reported once"

FAKE_LIVE_UNITS="prefix-one.service"
_nixos_targets="$(run_targets NixOS)" || true
assert_eq $'plain-nixos\nprefix-one.service' "$_nixos_targets" \
  "the NixOS host yields its own live targets"

section 2 "Enable clears gates without starting anything"

: >"$FAKE_SVC_LOG"
FAKE_LIVE_LABELS="local.prefix.one"
run_enable MacBook >/dev/null 2>&1 || true
assert_eq $'enable plain-macos\nenable local.prefix.one' "$(cat "$FAKE_SVC_LOG")" \
  "each live target is enabled once"
assert_no_start "$(cat "$FAKE_SVC_LOG")" "the enable pass never calls start"

section 3 "A failed enable stops the rebuild"

marker="$_tmp/rebuild.marker"
run_gate_then_rebuild() { # models apply's gate-then-rebuild sequence
  run_enable MacBook >/dev/null 2>&1 && printf 'rebuilt\n' >"$marker"
}

: >"$FAKE_SVC_LOG"
FAKE_SVC_FAIL_TARGET="local.prefix.one"
_rc=0
run_gate_then_rebuild || _rc=$?
assert_eq "1" "$_rc" "a failing enable exits non-zero"
if [ -e "$marker" ]; then
  assert_fail "a failing enable prevents the rebuild marker" "marker exists at $marker"
else
  assert_pass "a failing enable prevents the rebuild marker"
fi
assert_no_start "$(cat "$FAKE_SVC_LOG")" "a failed enable pass never calls start"

section 4 "Gate clearing precedes rebuild, and repair starts only missing targets"

# The harness runs the two gate functions extracted from apply.sh. Its repo
# holds a copy of the fixture registry and a fake svc.sh, so no case builds,
# activates, or resolves a service through the real apply path.
HARNESS_REPO="$_tmp/harness-repo"
HARNESS_SH="$_tmp/apply-gate-harness.sh"
mkdir -p "$HARNESS_REPO/src/modules" "$HARNESS_REPO/src/scripts/services" "$HARNESS_REPO/scripts"
cp "$REGISTRY" "$HARNESS_REPO/src/modules/services.json"
cp "$FAKE_SVC" "$HARNESS_REPO/scripts/svc.sh"
cp "$ENABLE_SH" "$HARNESS_REPO/src/scripts/services/managed-services-enable.sh"
ln -s "$REPO_ROOT/src/scripts/lib" "$HARNESS_REPO/src/scripts/lib"

{
  cat <<'HARNESS_HEADER'
#!/usr/bin/env bash
set -euo pipefail
say() { :; }
die() {
  printf 'die: %s\n' "$*" >&2
  exit 1
}
HARNESS_HEADER
  printf 'REPO_ROOT=%q\n' "$HARNESS_REPO"
  printf 'SCRIPT_DIR=%q\n' "$HARNESS_REPO/src/scripts"
  printf '_NUCLEUS_LIB_SOURCED=1\n'
  printf '. %q\n' "$TARGETS_LIB"
  printf '. %q\n' "$REPO_ROOT/src/scripts/lib/macos-launch-services.sh"
  printf '. %q\n' "$REPO_ROOT/src/scripts/lib/supervisor-systemd.sh"
  extract_func clear_managed_service_gates "$APPLY_SH"
  printf '\n'
  extract_func repair_managed_service_gates "$APPLY_SH"
  cat <<'HARNESS_FOOTER'
_apply_cleared_targets="${2:-}"
case "${1:-}" in
gate-then-rebuild)
  clear_managed_service_gates MacBook
  printf 'rebuild\n' >>"$FAKE_SVC_LOG"
  repair_managed_service_gates MacBook
  ;;
repair)
  repair_managed_service_gates "${3:-MacBook}"
  ;;
*)
  printf 'unknown harness mode %s\n' "$1" >&2
  exit 2
  ;;
esac
HARNESS_FOOTER
} >"$HARNESS_SH"
chmod +x "$HARNESS_SH"

if [ -z "$(extract_func clear_managed_service_gates "$APPLY_SH")" ] ||
  [ -z "$(extract_func repair_managed_service_gates "$APPLY_SH")" ]; then
  assert_fail "apply defines both managed service gate functions" \
    "extract_func returned nothing from $APPLY_SH"
  finish_tests
fi

set_probe_state() { # <live-labels> <loaded-labels> [probe-exit] [message]
  FAKE_LIVE_LABELS="$1"
  FAKE_LOADED_LABELS="$2"
  FAKE_PROBE_EXIT="${3:-}"
  FAKE_PROBE_MESSAGE="${4:-probe failed}"
  export FAKE_LIVE_LABELS FAKE_LOADED_LABELS FAKE_PROBE_EXIT FAKE_PROBE_MESSAGE
}

run_gate() { # <mode> [targets] [host]
  fake_env bash "$HARNESS_SH" "$@"
}

: >"$FAKE_SVC_LOG"
FAKE_SVC_FAIL_TARGET=""
set_probe_state "local.prefix.one" "" ""
_rc=0
run_gate gate-then-rebuild >/dev/null 2>&1 || _rc=$?
assert_eq "0" "$_rc" "gate clearing and repair finish without a real apply"
assert_eq $'enable plain-macos\nenable local.prefix.one\nrebuild\nstart plain-macos\nstart local.prefix.one' "$(cat "$FAKE_SVC_LOG")" \
  "enable runs before rebuild and both missing jobs start after it"
assert_eq "1" "$(grep -cx 'start local.prefix.one' "$FAKE_SVC_LOG")" \
  "an unloaded launchd instance starts once after rebuild"

: >"$FAKE_SVC_LOG"
set_probe_state "" "local.plain-macos" ""
_rc=0
run_gate repair "plain-macos" MacBook >/dev/null 2>&1 || _rc=$?
assert_eq "0" "$_rc" "a loaded launchd job is probed without error"
assert_eq "" "$(cat "$FAKE_SVC_LOG")" "a loaded launchd job is not started after rebuild"

: >"$FAKE_SVC_LOG"
set_probe_state "" "" 2 "probe broke"
_rc=0
_error="$(run_gate repair "plain-macos" MacBook 2>&1)" || _rc=$?
assert_eq "1" "$_rc" "a failed loaded-state probe hard-errors"
assert_contains "$_error" "loaded-state probe for plain-macos failed with launchctl exit 2" \
  "the hard error names the target and the probe exit code"
assert_no_start "$(cat "$FAKE_SVC_LOG")" "a failed probe never starts the target"

: >"$FAKE_SVC_LOG"
FAKE_ENABLED_UNITS="plain-nixos.service"
FAKE_LIVE_UNITS=""
export FAKE_ENABLED_UNITS FAKE_LIVE_UNITS
_rc=0
run_gate repair $'plain-nixos\nplain-nixos' NixOS >/dev/null 2>&1 || _rc=$?
assert_eq "0" "$_rc" "duplicate target lines are repaired without error"
assert_eq "start plain-nixos" "$(cat "$FAKE_SVC_LOG")" \
  "duplicate target lines start the systemd unit once"

: >"$FAKE_SVC_LOG"
FAKE_LIVE_UNITS="plain-nixos.service"
export FAKE_LIVE_UNITS
_rc=0
run_gate repair "plain-nixos" NixOS >/dev/null 2>&1 || _rc=$?
assert_eq "0" "$_rc" "a loaded systemd unit is probed without error"
assert_eq "" "$(cat "$FAKE_SVC_LOG")" "a loaded systemd unit is not started after rebuild"

: >"$FAKE_SVC_LOG"
FAKE_ENABLED_UNITS="plain-nixos.service"
FAKE_LIVE_UNITS=""
FAKE_SYSTEMCTL_PROBE_EXIT=4
FAKE_SYSTEMCTL_PROBE_MESSAGE="load state unreadable"
export FAKE_ENABLED_UNITS FAKE_LIVE_UNITS FAKE_SYSTEMCTL_PROBE_EXIT FAKE_SYSTEMCTL_PROBE_MESSAGE
_rc=0
_error="$(run_gate repair "plain-nixos" NixOS 2>&1)" || _rc=$?
assert_eq "1" "$_rc" "a failed systemd load-state probe hard-errors"
assert_contains "$_error" "could not read the load state of plain-nixos" \
  "the systemd hard error names the target"
assert_no_start "$(cat "$FAKE_SVC_LOG")" "a failed systemd probe never starts the target"

finish_tests
