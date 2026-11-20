#!/usr/bin/env bash
# Tests for nucleus-svc unblock and --unblock. A blocked/crash-looping instance
# can be re-armed without a full apply by clearing its health record: the
# `unblock` action clears resolved live or configured targets and reports each
# cleared instance, and `--unblock` clears before start/restart in either
# argument order. The flag is rejected on other actions and missing targets are
# rejected like any other action.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

ensure_safe_rm_env
init_test_state

require_command jq "svc unblock tests inspect health records and CLI JSON with jq"

# shellcheck source=../../src/scripts/lib/service-health.sh
. "$REPO_ROOT/src/scripts/lib/service-health.sh"

SVC_SH="$REPO_ROOT/scripts/svc.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  *) return 1 ;;
  esac
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3" "expected '$1', got '$2'"
  fi
}

record_state() {
  jq -r '.state // "missing"' "$(svc_health_state_file "$1")" 2>/dev/null || printf 'missing'
}

mkdir -p "$_tmp/repo/src/modules" "$_tmp/bin" "$_tmp/home" "$_tmp/log"

cat >"$_tmp/repo/src/modules/services.json" <<JSON
{
  "\$logging": {
    "MacBook": {
      "logDir": "$_tmp/log",
      "systemLogDir": "$_tmp/syslog"
    }
  },
  "demo": {
    "displayName": "Demo",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "service": "local.demo",
        "scope": "user",
        "launchdDomain": "gui"
      }
    }
  },
  "cloud-drive": {
    "displayName": "Cloud Drive Mounts",
    "hosts": {
      "MacBook": {
        "type": "macos-launchctl",
        "prefixMatch": true,
        "service": "local.cloud-mount.",
        "scope": "user",
        "launchdDomain": "gui"
      }
    }
  }
}
JSON

cp -R "$REPO_ROOT/tests/fixtures/user-registry/src/users" "$_tmp/repo/src/users"

FAKE_LOG="$_tmp/launchctl.log"
FAKE_STATE="$_tmp/job.state"
FAKE_GATE="$_tmp/gate.state"
export FAKE_LOG FAKE_STATE FAKE_GATE

cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
_state() { cat "$FAKE_STATE" 2>/dev/null || printf 'absent\n'; }
_gate() { cat "$FAKE_GATE" 2>/dev/null || printf 'enabled\n'; }
case "${1:-}" in
list)
  printf 'PID\tStatus\tLabel\n'
  if [ "$(_state)" = "loaded" ]; then
    printf '4242\t0\tlocal.demo\n'
    printf '4242\t0\tlocal.cloud-mount.iCloud\n'
  fi
  ;;
print)
  target="${*: -1}"
  case "$target" in
  *local.demo|*local.cloud-mount.iCloud)
    if [ "$(_state)" = "loaded" ]; then
      printf 'state = running\n\tpid = 4242\n'
      exit 0
    fi
    ;;
  esac
  printf 'Could not find service\n' >&2
  exit 113
  ;;
print-disabled)
  printf '\n\tdisabled services = {\n'
  if [ "$(_gate)" = "disabled" ]; then
    printf '\t\t"local.demo" => disabled\n'
  fi
  printf '\t}\n'
  ;;
kill)
  exit 0
  ;;
bootout)
  printf 'absent\n' >"$FAKE_STATE"
  exit 0
  ;;
bootstrap|start)
  printf 'loaded\n' >"$FAKE_STATE"
  exit 0
  ;;
enable|disable)
  exit 0
  ;;
esac
exit 0
FAKE_LAUNCHCTL
cat >"$_tmp/bin/sw_vers" <<'FAKE_SW_VERS'
#!/usr/bin/env bash
printf '27.0\n'
FAKE_SW_VERS
cat >"$_tmp/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
cat >"$_tmp/bin/mount" <<'FAKE_MOUNT'
#!/usr/bin/env bash
exit 0
FAKE_MOUNT
chmod +x "$_tmp/bin/launchctl" "$_tmp/bin/sw_vers" "$_tmp/bin/sleep" "$_tmp/bin/mount"

run_svc() {
  env NUCLEUS_HOST=MacBook \
    NUCLEUS_REPO_ROOT="$_tmp/repo" \
    HOME="$_tmp/home" \
    NUCLEUS_USER_ROOT="$NUCLEUS_USER_ROOT" \
    NUCLEUS_LOG_DIR="$_tmp/log" \
    SUDO_USER=test-user \
    PATH="$_tmp/bin:$PATH" \
    bash "$SVC_SH" "$@"
}

reset_cli() {
  printf 'loaded\n' >"$FAKE_STATE"
  printf 'enabled\n' >"$FAKE_GATE"
  : >"$FAKE_LOG"
  cli_status=0
  cli_output="$(run_svc "$@" 2>&1)" || cli_status=$?
}

section 1 "unblock clears a blocked record and reports the instance"

svc_health_set_blocked demo crash-loop "restart storm"
assert_eq "blocked" "$(record_state demo)" "seeded demo record is blocked"
reset_cli unblock demo
assert_eq "0" "$cli_status" "unblock exits 0"
assert_eq "stopped" "$(record_state demo)" "unblock clears the blocked record"
if contains "$cli_output" "unblocked demo"; then
  assert_pass "unblock reports the cleared instance"
else
  assert_fail "unblock reports the cleared instance" "$cli_output"
fi

section 2 "unblock is a no-op when not blocked"

svc_health_clear demo
reset_cli unblock demo
assert_eq "0" "$cli_status" "unblock exits 0 for a clear record"
if contains "$cli_output" "unblocked demo"; then
  assert_pass "unblock still reports the instance when nothing was blocked"
else
  assert_fail "unblock still reports the instance when nothing was blocked" "$cli_output"
fi

section 3 "unblock clears a configured but not loaded instance"

# cloud-drive mounts are discovered from the user registry; add a declared mount so
# the configured-but-not-loaded path resolves without a live launchd instance.
cat >"$_tmp/repo/src/users/test-user/cloud-drives.json" <<'JSON'
{
  "$schema": "../default/cloud-drives.schema.json",
  "mounts": [
    {
      "enable": true,
      "id": "iCloud",
      "provider": "iCloud",
      "remoteName": "iCloud",
      "localPath": { "MacBook": "clouds/iCloud", "NixOS": "clouds/iCloud", "Windows": "clouds\\iCloud" },
      "remotePath": "/"
    }
  ],
  "replicas": []
}
JSON

svc_health_set_blocked local.cloud-mount.iCloud crash-loop "not loaded"
assert_eq "blocked" "$(record_state local.cloud-mount.iCloud)" "configured instance seeded blocked"
printf 'absent\n' >"$FAKE_STATE"
: >"$FAKE_LOG"
cli_status=0
cli_output="$(run_svc unblock local.cloud-mount.iCloud 2>&1)" || cli_status=$?
assert_eq "0" "$cli_status" "unblock exits 0 for a configured instance"
assert_eq "stopped" "$(record_state local.cloud-mount.iCloud)" "unblock clears a configured instance record"
if contains "$cli_output" "unblocked local.cloud-mount.iCloud"; then
  assert_pass "unblock reports a configured instance"
else
  assert_fail "unblock reports a configured instance" "$cli_output"
fi

cat >"$_tmp/repo/src/users/test-user/cloud-drives.json" <<'JSON'
{
  "$schema": "../default/cloud-drives.schema.json",
  "replicas": [
    {
      "direction": "pull",
      "enable": false,
      "fallbackTimer": {"enable": true, "interval": "daily"},
      "id": "GoogleDrive",
      "localPath": {"MacBook": "clouds/GoogleDriveReplica", "NixOS": "clouds/GoogleDriveReplica", "Windows": "clouds\\GoogleDriveReplica"},
      "name": "Google Drive",
      "provider": "GoogleDrive",
      "readWrite": false,
      "remotePath": "/"
    },
    {
      "direction": "pull",
      "enable": true,
      "fallbackTimer": {"enable": true, "interval": "daily"},
      "iCloudService": "drive",
      "id": "iCloud",
      "localPath": {"MacBook": "clouds/iCloudReplica", "NixOS": "clouds/iCloudReplica", "Windows": "clouds\\iCloudReplica"},
      "provider": "iCloud",
      "readWrite": {"MacBook": true, "NixOS": false, "Windows": false},
      "remotePath": "/"
    },
    {
      "direction": "pull",
      "enable": true,
      "fallbackTimer": {"enable": true, "interval": "daily"},
      "id": "OneDrive",
      "localPath": {"MacBook": "clouds/OneDriveReplica", "NixOS": "clouds/OneDriveReplica", "Windows": "clouds\\OneDriveReplica"},
      "provider": "OneDrive",
      "readWrite": false,
      "remotePath": "/"
    }
  ]
}
JSON

section 4 "restart --unblock clears before restart in both orders"

for _order in "restart demo --unblock" "restart --unblock demo"; do
  svc_health_set_blocked demo crash-loop "restart storm"
  read -r -a _argv <<<"$_order"
  reset_cli "${_argv[@]}"
  assert_eq "0" "$cli_status" "'$_order' exits 0"
  assert_eq "stopped" "$(record_state demo)" "'$_order' clears the blocked record"
  if contains "$cli_output" "blocked"; then
    assert_fail "'$_order' does not report a blocked state after clearing" "$cli_output"
  else
    assert_pass "'$_order' clears before restart"
  fi
done

section 5 "start --unblock clears before start in both orders"

for _order in "start demo --unblock" "start --unblock demo"; do
  svc_health_set_blocked demo crash-loop "restart storm"
  read -r -a _argv <<<"$_order"
  reset_cli "${_argv[@]}"
  assert_eq "0" "$cli_status" "'$_order' exits 0"
  assert_eq "stopped" "$(record_state demo)" "'$_order' clears the blocked record"
done

section 6 "--unblock is rejected on other actions"

reset_cli stop demo --unblock
assert_eq "1" "$cli_status" "stop --unblock is rejected"
if contains "$cli_output" "--unblock" && contains "$cli_output" "start" && contains "$cli_output" "restart"; then
  assert_pass "rejection names --unblock and the actions it belongs to"
else
  assert_fail "rejection names --unblock and the actions it belongs to" "$cli_output"
fi
assert_eq "" "$(awk '{printf "%s ", $1}' "$FAKE_LOG")" "a rejected action performs no service-manager call"

section 7 "missing and invalid targets are rejected"

reset_cli unblock
assert_eq "1" "$cli_status" "unblock without a service name is rejected"
if contains "$cli_output" "service" || contains "$cli_output" "missing"; then
  assert_pass "missing service name is reported"
else
  assert_fail "missing service name is reported" "$cli_output"
fi

reset_cli unblock no-such-service
assert_eq "1" "$cli_status" "unblock rejects an unknown service"
if contains "$cli_output" "not found"; then
  assert_pass "unknown service is reported"
else
  assert_fail "unknown service is reported" "$cli_output"
fi

_cloud_drives_json="$_tmp/repo/src/users/test-user/cloud-drives.json"
cp "$_cloud_drives_json" "${_cloud_drives_json}.bak"
printf '{"mounts":[],"replicas":[]}\n' >"$_cloud_drives_json"
printf 'absent\n' >"$FAKE_STATE"
: >"$FAKE_LOG"
cli_status=0
cli_output="$(run_svc unblock cloud-drive 2>&1)" || cli_status=$?
assert_eq "1" "$cli_status" "unblock rejects a prefix-match key with no instances"
if contains "$cli_output" "no instances"; then
  assert_pass "prefix-match key with no instances is reported"
else
  assert_fail "prefix-match key with no instances is reported" "$cli_output"
fi
mv "${_cloud_drives_json}.bak" "$_cloud_drives_json"

finish_tests
