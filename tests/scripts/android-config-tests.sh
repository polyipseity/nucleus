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
        "gappsUrl": "https://example.invalid/gapps.zip",
        "magiskUrl": "https://example.invalid/Magisk.apk"
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
  *disconnect*) exit 0 ;;
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
  *disconnect*) exit 0 ;;
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
  *disconnect*) exit 0 ;;
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
  if ! grep -q 'Magisk' "$_tmp/out.txt"; then
    echo "FAIL: expected manual workflow to mention Magisk"
    _failures=$((_failures + 1))
  fi
}

test_root_enables_debuggable_and_root_access() {
  setup_fixture
  _af_shell_log="$_tmp/shell.log"
  : > "$_af_shell_log"
  _af_root_attempts=0
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *disconnect*) exit 0 ;;
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	device' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'device\n' ;;
  *' root')
    _af_root_attempts=\$((_af_root_attempts + 1))
    echo "root \$*" >> "$_af_shell_log"
    exit 0
    ;;
  *shell*settings*) echo "settings \$*" >> "$_af_shell_log"; exit 0 ;;
  *shell*su\ -c*pm\ path*) echo "su \$*" >> "$_af_shell_log"; printf 'package:/system/app/Terminal/Terminal.apk\n'; exit 0 ;;
  *shell*su\ -c*com.android.terminal*) echo "su \$*" >> "$_af_shell_log"; printf '1\n'; exit 0 ;;
  *shell*su\ -c*resetprop*) echo "su \$*" >> "$_af_shell_log"; exit 0 ;;
  *shell*su\ -c*nucleus-root-props*) echo "su \$*" >> "$_af_shell_log"; exit 0 ;;
  *shell*su\ -c*service.d*) echo "su \$*" >> "$_af_shell_log"; exit 0 ;;
  *shell*su\ -c*magiskpolicy*) echo "su \$*" >> "$_af_shell_log"; exit 0 ;;
  *shell*su\ -c*) echo "su \$*" >> "$_af_shell_log"; printf '0\n'; exit 0 ;;
  *shell*id*) printf '0\n'; exit 0 ;;
  *shell*setprop*) echo "setprop \$*" >> "$_af_shell_log"; exit 0 ;;
  *push*) exit 0 ;;
  *shell*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  cat > "$_af_bin/fastboot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$_af_bin/fastboot"
  PATH="$_af_bin:$PATH"
  export PATH

  if ! vm_android_config Android 0 --root >"$_tmp/out.txt" 2>&1; then
    echo "FAIL: --root should succeed when Magisk su and adb root are available"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'settings put global development_settings_enabled' "$_af_shell_log"; then
    echo "FAIL: --root should enable Developer options via settings put global"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'com.android.terminal' "$_af_shell_log"; then
    echo "FAIL: --root should enable Local terminal (com.android.terminal)"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'resetprop ro.debuggable 1' "$_af_shell_log"; then
    echo "FAIL: --root should apply resetprop ro.debuggable 1"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'nucleus-root-props.sh' "$_af_shell_log"; then
    echo "FAIL: --root should persist nucleus-root-props.sh in service.d"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'adb root ready' "$_tmp/out.txt"; then
    echo "FAIL: --root should report adb root ready"
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
  *disconnect*) exit 0 ;;
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
  printf 'test-release\n' > "$_tmp/vm/images/android-recovery-userdebug.flashed"

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
  *disconnect*) exit 0 ;;
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
  *getvar*is-userspace*) printf 'is-userspace: yes\n'; exit 0 ;;
  *getvar*version*) exit 0 ;;
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
  if ! grep -q 'Enable ADB' "$_tmp/out.txt"; then
    echo "FAIL: expected Enable ADB guidance after fastboot flash"
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

  _af_sideload_log="$_tmp/sideload.log"
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *disconnect*) exit 0 ;;
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	sideload' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'sideload\n' ;;
  *getprop*ro.build.type*) printf 'userdebug\n' ;;
  *getprop*ro.debuggable*) printf '0\n' ;;
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
  if ! grep -q 'already in sideload mode' "$_tmp/out.txt"; then
    echo "FAIL: expected already-in-sideload detection"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'ro.build.type=userdebug' "$_tmp/out.txt"; then
    echo "FAIL: expected guest userdebug recovery detection"
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

test_adb_keys_in_recovery() {
  setup_fixture
  _af_push_log="$_tmp/push.log"
  _af_home="$_tmp/home"
  mkdir -p "$_af_home/.android"
  printf 'test-adb-key\n' > "$_af_home/.android/adbkey.pub"
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *disconnect*) exit 0 ;;
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	recovery' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'recovery\n' ;;
  *getprop*) exit 0 ;;
  *setprop*) exit 0 ;;
  *' root') exit 0 ;;
  *shell*id*) printf '0\n' ;;
  *push*) echo "push \$*" >> "$_af_push_log"; exit 0 ;;
  *shell*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  cat > "$_af_bin/fastboot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$_af_bin/fastboot"
  HOME="$_af_home" PATH="$_af_bin:$PATH" vm_android_config Android 0 --adb-keys || {
    echo "FAIL: --adb-keys should succeed in recovery"
    _failures=$((_failures + 1))
  }
  if [ ! -f "$_af_push_log" ]; then
    echo "FAIL: expected adb push for adb-keys in recovery"
    _failures=$((_failures + 1))
  fi
}

test_magisk_stage_patch_kit_layout() {
  setup_fixture
  _af_apk_root="$_tmp/magisk-apk-root"
  _af_apk="$_tmp/magisk-mini.apk"
  mkdir -p "$_af_apk_root/assets" "$_af_apk_root/lib/arm64-v8a"
  printf '#!/system/bin/sh\n' > "$_af_apk_root/assets/boot_patch.sh"
  printf 'util\n' > "$_af_apk_root/assets/util_functions.sh"
  printf 'apk\n' > "$_af_apk_root/assets/stub.apk"
  printf 'magisk\n' > "$_af_apk_root/lib/arm64-v8a/libmagisk.so"
  printf 'boot\n' > "$_af_apk_root/lib/arm64-v8a/libmagiskboot.so"
  printf 'init\n' > "$_af_apk_root/lib/arm64-v8a/libmagiskinit.so"
  printf 'ld\n' > "$_af_apk_root/lib/arm64-v8a/libinit-ld.so"
  (
    cd "$_af_apk_root"
    zip -qr "$_af_apk" assets lib
  )
  _af_stage="$_tmp/magisk-stage"
  if ! vm_android_magisk_stage_patch_kit "$_af_apk" 0 "$_af_stage"; then
    echo "FAIL: vm_android_magisk_stage_patch_kit should succeed for a minimal APK"
    _failures=$((_failures + 1))
    return
  fi
  for _af_bin in magisk magiskboot magiskinit init-ld boot_patch.sh stub.apk; do
    if [ ! -f "$_af_stage/$_af_bin" ]; then
      echo "FAIL: staged patch kit missing $_af_bin"
      _failures=$((_failures + 1))
    fi
  done
}

test_magisk_download_stdout_is_path_only() {
  setup_fixture
  _af_apk="$IMAGES_DIR/android-magisk.apk"
  _af_boot="$IMAGES_DIR/android-boot.img"
  printf 'cached\n' > "$_af_apk"
  printf 'boot\n' > "$_af_boot"
  jq -n --arg tag 'test-tag' '{tag_name: $tag}' > "$IMAGES_DIR/android-boot.tag.json"

  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *boot_arm64only.img*) printf 'location: https://github.com/jqssun/android-lineage-qemu/releases/download/test-tag/boot_arm64only.img\n' ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/curl"
  PATH="$_af_bin:$PATH"
  export PATH

  _af_apk_out="$(vm_android_download_magisk_apk 0)"
  if [ "$_af_apk_out" != "$_af_apk" ]; then
    echo "FAIL: download_magisk_apk stdout should be only the APK path"
    _failures=$((_failures + 1))
  fi
  if printf '%s' "$_af_apk_out" | grep -q 'vm:'; then
    echo "FAIL: download_magisk_apk stdout must not include say() log lines"
    _failures=$((_failures + 1))
  fi

  _af_boot_out="$(vm_android_download_boot_image 0)"
  if [ "$_af_boot_out" != "$_af_boot" ]; then
    echo "FAIL: download_boot_image stdout should be only the boot image path"
    _failures=$((_failures + 1))
  fi
  if printf '%s' "$_af_boot_out" | grep -q 'vm:'; then
    echo "FAIL: download_boot_image stdout must not include say() log lines"
    _failures=$((_failures + 1))
  fi
}

test_android_config_magisk_configures_existing_su() {
  setup_fixture
  _af_shell_log="$_tmp/shell.log"
  : > "$_af_shell_log"
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *disconnect*) exit 0 ;;
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	device' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'device\n' ;;
  *getprop*ro.build.display.id*) printf 'lineage_test\n' ;;
  *shell*settings*) echo "settings \$*" >> "$_af_shell_log"; exit 0 ;;
  *shell*su\ -c*) echo "su \$*" >> "$_af_shell_log"; printf '0\n'; exit 0 ;;
  *push*) exit 0 ;;
  *shell*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  cat > "$_af_bin/fastboot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$_af_bin/fastboot"
  cat > "$_af_bin/unzip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$_af_bin/unzip"
  PATH="$_af_bin:$PATH"
  export PATH

  if ! vm_android_config Android 0 --magisk >"$_tmp/out.txt" 2>&1; then
    echo "FAIL: --magisk should succeed when Magisk su is already available"
    _failures=$((_failures + 1))
  fi
  if grep -q 'settings put global adb_enabled' "$_af_shell_log"; then
    echo "FAIL: --magisk must not enable USB debugging (use --root instead)"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'Magisk installed' "$_tmp/out.txt"; then
    echo "FAIL: --magisk should report Magisk installed"
    _failures=$((_failures + 1))
  fi
  if grep -q 'nucleus-adb-root' "$_tmp/out.txt" || grep -q 'nucleus-root-props' "$_af_shell_log" || grep -q 'adb root' "$_af_shell_log"; then
    echo "FAIL: --magisk must not install root props or enable adb root"
    _failures=$((_failures + 1))
  fi
}

test_wait_boot_completed_waits_for_sys_boot_completed() {
  setup_fixture
  _af_boot_file="$_tmp/boot_completed"
  printf '0' > "$_af_boot_file"
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *disconnect*) exit 0 ;;
  *devices*) printf '%s\n' 'List of devices attached' 'localhost:22040	device' '' ;;
  *connect*) exit 0 ;;
  *get-state*) printf 'device\n' ;;
  *shell*getprop*sys.boot_completed*) cat "$_af_boot_file"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  PATH="$_af_bin:$PATH"
  export PATH

  set +e
  vm_android_adb_wait_boot_completed 0 3 >"$_tmp/out.txt" 2>&1
  _af_status=$?
  set -e
  if [ "$_af_status" -eq 0 ]; then
    echo "FAIL: wait_boot_completed should block while sys.boot_completed is 0"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'still booting' "$_tmp/out.txt"; then
    echo "FAIL: expected still-booting hint while sys.boot_completed is 0"
    _failures=$((_failures + 1))
  fi

  printf '1' > "$_af_boot_file"
  if ! vm_android_adb_wait_boot_completed 0 5; then
    echo "FAIL: wait_boot_completed should succeed when sys.boot_completed is 1"
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
  *getvar*is-userspace*) echo "getvar \$*" >> "$_af_probe_log"; printf 'is-userspace: yes\n' >&2; exit 0 ;;
  *getvar*version*) echo "getvar \$*" >> "$_af_probe_log"; printf 'version: test\n' >&2; exit 0 ;;
esac
exit 1
EOF
  chmod +x "$_af_bin/fastboot"
  PATH="$_af_bin:$PATH"
  export PATH
  assert_eq "fastboot" "$(vm_android_fastboot_list_state 0)" "fastboot probe via getvar"
  if ! grep -q 'getvar is-userspace' "$_af_probe_log"; then
    echo "FAIL: expected fastboot getvar is-userspace probe"
    _failures=$((_failures + 1))
  fi
}

test_fastboot_wait_detects_existing_fastboot() {
  setup_fixture
  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/fastboot" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *getvar*is-userspace*) printf 'is-userspace: yes\n' >&2; exit 0 ;;
esac
exit 1
EOF
  chmod +x "$_af_bin/fastboot"
  PATH="$_af_bin:$PATH"
  export PATH
  if ! vm_android_fastboot_wait 0 5 >"$_tmp/out.txt" 2>&1; then
    echo "FAIL: fastboot_wait should succeed when guest is already in fastboot"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'guest already in fastboot' "$_tmp/out.txt"; then
    echo "FAIL: expected immediate fastboot detection"
    _failures=$((_failures + 1))
  fi
}

test_adb_port_resolution
test_adb_list_state_unauthorized
test_wait_authorized_fails_on_unauthorized
test_wait_recovery_succeeds_on_recovery
test_no_flags_prints_manual
test_root_enables_debuggable_and_root_access
test_gapps_rejects_booted_device_state
test_gapps_unauthorized_flashes_recovery
test_gapps_sideload_path
test_adb_keys_in_recovery
test_magisk_stage_patch_kit_layout
test_magisk_download_stdout_is_path_only
test_wait_boot_completed_waits_for_sys_boot_completed
test_android_config_magisk_configures_existing_su
test_fastboot_probe_uses_getvar
test_fastboot_wait_detects_existing_fastboot

if [ "$_failures" -gt 0 ]; then
  echo "android-config-tests: $_failures failure(s)"
  exit 1
fi
echo "android-config-tests: all passed"
