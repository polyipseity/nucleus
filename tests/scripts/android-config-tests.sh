#!/usr/bin/env bash
# Unit tests for android-config.sh flag parsing, ADB authorization, and GApps sideload.
#
# Run with: bash tests/scripts/android-config-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"
# shellcheck source=../../src/scripts/vms/android-config.sh
. "$REPO_ROOT/src/scripts/vms/android-config.sh"

_failures=0
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: $3: expected '$1', got '$2'"
    _failures=$((_failures + 1))
  fi
}

setup_fixture() {
  _af_manifest="$_tmp/manifest.json"
  cat > "$_af_manifest" <<'EOF'
{
  "VMs": [
    {
      "id": "Android",
      "name": "Android",
      "type": "Android",
      "enabled": true,
      "hosts": ["MacBook"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "64GB",
      "portForwards": [
        {"guestPort": 5555, "hostPort": 22040},
        {"guestPort": 5554, "hostPort": 22041}
      ],
      "macAddressPrefix": "52",
      "Android": {
        "systemImage": "Android-system.qcow2",
        "userdataImage": "Android.qcow2",
        "gsiImage": "Android-gsi.img",
        "gsiUrl": null,
        "gappsUrl": "https://example.invalid/gapps.zip"
      }
    }
  ]
}
EOF
  vm_init "$REPO_ROOT" "$_tmp/vm" "$_tmp/vm/images" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$REPO_ROOT/src/vms" "$_af_manifest" "MacBook" "false" "false"
}

test_adb_port_resolution() {
  setup_fixture
  assert_eq "22040" "$(vm_android_adb_host_port 0)" "ADB host port from manifest"
  assert_eq "22041" "$(vm_android_fastboot_host_port 0)" "fastboot host port from manifest"
  assert_eq "localhost:22040" "$(vm_android_adb_serial 0)" "ADB serial"
  assert_eq "tcp:localhost:22041" "$(vm_android_fastboot_serial 0)" "fastboot serial"
}

test_adb_list_state_unauthorized() {
  setup_fixture
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	unauthorized' '' ;;
  *connect*) exit 0 ;;
  *get-state*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  PATH="$_af_bin:$PATH"
  export PATH
  assert_eq "unauthorized" "$(vm_android_adb_list_state 0)" "adb devices unauthorized state"
}

test_wait_authorized_fails_on_unauthorized() {
  setup_fixture
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	unauthorized' '' ;;
  *connect*) exit 0 ;;
  *get-state*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  PATH="$_af_bin:$PATH"
  export PATH

  set +e
  vm_android_adb_wait_authorized 0 1 2>"$_tmp/err.txt"
  _af_status=$?
  set -e
  if [ "$_af_status" -eq 0 ]; then
    echo "FAIL: vm_android_adb_wait_authorized should fail when unauthorized"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'ADB authorization' "$_tmp/err.txt"; then
    echo "FAIL: expected ADB authorization timeout error"
    _failures=$((_failures + 1))
  fi
}

test_wait_recovery_succeeds_on_recovery() {
  setup_fixture
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	recovery' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'recovery\n' ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  PATH="$_af_bin:$PATH"
  export PATH

  if ! vm_android_adb_wait_recovery 0 1; then
    echo "FAIL: vm_android_adb_wait_recovery should succeed in recovery state"
    _failures=$((_failures + 1))
  fi
}

test_no_flags_prints_manual() {
  setup_fixture
  set +e
  vm_android_config Android 0 >"$_tmp/out.txt" 2>&1
  _af_status=$?
  set -e
  if [ "$_af_status" -ne 0 ]; then
    echo "FAIL: vm_android_config without flags should succeed and print the manual"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'Enter fastboot' "$_tmp/out.txt"; then
    echo "FAIL: expected manual workflow with Enter fastboot step"
    _failures=$((_failures + 1))
  fi
}

test_gapps_rejects_booted_device_state() {
  setup_fixture
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	device' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'device\n' ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  cat > "$_af_bin/fastboot" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *getvar*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$_af_bin/fastboot"
  PATH="$_af_bin:$PATH"
  export PATH

  set +e
  vm_android_config Android 0 --gapps 2>"$_tmp/err.txt"
  _af_status=$?
  set -e
  if [ "$_af_status" -eq 0 ]; then
    echo "FAIL: --gapps should fail when guest is booted to system"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'booted to system' "$_tmp/err.txt"; then
    echo "FAIL: expected booted-system error message"
    _failures=$((_failures + 1))
  fi
}

test_gapps_unauthorized_flashes_recovery() {
  setup_fixture
  mkdir -p "$_tmp/vm/images"
  _af_zip="$_tmp/vm/images/android-gapps.zip"
  _af_recovery="$_tmp/vm/images/android-recovery-userdebug.img"
  printf 'PK\x03\x04' > "$_af_zip"
  printf 'recovery\n' > "$_af_recovery"

  _af_flash_log="$_tmp/flash.log"
  _af_sideload_log="$_tmp/sideload.log"
  _af_state_file="$_tmp/adb-state"
  printf 'unauthorized\n' > "$_af_state_file"
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
_af_state="\$(cat "$_af_state_file")"
case "\$*" in
  *devices*) printf '%s\n' 'List of devices attached' "localhost:22040	\$_af_state" '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf '%s\n' "\$_af_state" ;;
  *reboot*fastboot*) printf 'offline\n' > "$_af_state_file"; exit 0 ;;
  *reboot*sideload*) printf 'sideload\n' > "$_af_state_file"; exit 0 ;;
  *sideload*) echo "sideload \$*" >> "$_af_sideload_log"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  cat > "$_af_bin/fastboot" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *getvar*) exit 0 ;;
  devices) printf '%s\n' 'tcp:localhost:22041	fastboot' '' ;;
  *flash*) echo "flash \$*" >> "$_af_flash_log"; exit 0 ;;
  *reboot*) printf 'recovery\n' > "$_af_state_file"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/fastboot"
  cat > "$_af_bin/curl" <<'EOF'
#!/usr/bin/env bash
_af_out=''
_af_head=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -I|-fsI) _af_head=true; shift ;;
    -o) _af_out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$_af_head" = true ]; then
  printf 'HTTP/2 302\nlocation: https://github.com/jqssun/android-lineage-qemu/releases/download/test-release/recovery_arm64only-userdebug.img\n\n'
  exit 0
fi
if [ -n "$_af_out" ]; then
  printf 'recovery\n' > "$_af_out"
fi
exit 0
EOF
  chmod +x "$_af_bin/curl"
  PATH="$_af_bin:$PATH"
  export PATH

  if ! vm_android_config Android 0 --gapps >"$_tmp/out.txt" 2>&1; then
    echo "FAIL: --gapps should proceed when recovery ADB is unauthorized"
    _failures=$((_failures + 1))
  fi
  if [ ! -f "$_af_flash_log" ]; then
    echo "FAIL: expected fastboot flash recovery when unauthorized"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'Enter fastboot' "$_tmp/out.txt"; then
    echo "FAIL: expected Enter fastboot guidance in output"
    _failures=$((_failures + 1))
  fi
}

test_gapps_sideload_path() {
  setup_fixture
  mkdir -p "$_tmp/vm/images"
  _af_zip="$_tmp/vm/images/android-gapps.zip"
  _af_recovery="$_tmp/vm/images/android-recovery-userdebug.img"
  printf 'PK\x03\x04' > "$_af_zip"
  printf 'recovery\n' > "$_af_recovery"
  jq -n --arg tag 'test-release' '{tag_name: $tag}' > "$_tmp/vm/images/android-recovery-userdebug.tag.json"
  printf 'test-release\n' > "$_tmp/vm/images/android-recovery-userdebug.flashed"

  _af_sideload_log="$_tmp/sideload.log"
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	sideload' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'sideload\n' ;;
  *sideload*) echo "sideload \$*" >> "$_af_sideload_log"; exit 0 ;;
  *reboot*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  cat > "$_af_bin/fastboot" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *getvar*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$_af_bin/fastboot"
  cat > "$_af_bin/curl" <<'EOF'
#!/usr/bin/env bash
_af_out=''
_af_head=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -I|-fsI) _af_head=true; shift ;;
    -o) _af_out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$_af_head" = true ]; then
  printf 'HTTP/2 302\nlocation: https://github.com/jqssun/android-lineage-qemu/releases/download/test-release/recovery_arm64only-userdebug.img\n\n'
  exit 0
fi
if [ -n "$_af_out" ]; then
  printf 'recovery\n' > "$_af_out"
fi
exit 0
EOF
  chmod +x "$_af_bin/curl"
  PATH="$_af_bin:$PATH"
  export PATH

  if ! vm_android_config Android 0 --gapps >"$_tmp/out.txt" 2>&1; then
    echo "FAIL: --gapps sideload path should succeed in sideload state"
    _failures=$((_failures + 1))
  fi
  if [ ! -f "$_af_sideload_log" ]; then
    echo "FAIL: expected adb sideload to run"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'Install anyway' "$_tmp/out.txt"; then
    echo "FAIL: expected manual Install anyway instructions"
    _failures=$((_failures + 1))
  fi
}

test_fastboot_probe_uses_getvar() {
  setup_fixture
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  _af_probe_log="$_tmp/fb-probe.log"
  cat > "$_af_bin/fastboot" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *getvar*) echo "getvar \$*" >> "$_af_probe_log"; exit 0 ;;
esac
exit 1
EOF
  chmod +x "$_af_bin/fastboot"
  PATH="$_af_bin:$PATH"
  export PATH
  assert_eq "fastboot" "$(vm_android_fastboot_list_state 0)" "fastboot probe via getvar"
  if ! grep -q 'getvar version' "$_af_probe_log"; then
    echo "FAIL: expected fastboot getvar version probe"
    _failures=$((_failures + 1))
  fi
}

test_adb_port_resolution
test_adb_list_state_unauthorized
test_wait_authorized_fails_on_unauthorized
test_wait_recovery_succeeds_on_recovery
test_no_flags_prints_manual
test_gapps_rejects_booted_device_state
test_gapps_unauthorized_flashes_recovery
test_gapps_sideload_path

if [ "$_failures" -gt 0 ]; then
  echo "android-config-tests: $_failures failure(s)"
  exit 1
fi
echo "android-config-tests: all passed"
