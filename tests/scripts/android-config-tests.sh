#!/usr/bin/env bash
# Unit tests for android-config.sh flag parsing and manifest port resolution.
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

assert_ne() {
  if [ "$1" = "$2" ]; then
    echo "FAIL: $3: expected values to differ, both were '$1'"
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

test_requires_at_least_one_flag() {
  setup_fixture
  set +e
  vm_android_config Android 0 2>"$_tmp/err.txt"
  _af_status=$?
  set -e
  if [ "$_af_status" -eq 0 ]; then
    echo "FAIL: vm_android_config without flags should fail"
    _failures=$((_failures + 1))
  fi
  if ! grep -q 'at least one' "$_tmp/err.txt"; then
    echo "FAIL: expected at-least-one-flag error message"
    _failures=$((_failures + 1))
  fi
}

test_gapps_cached_zip_skips_download() {
  setup_fixture
  mkdir -p "$_tmp/vm/images"
  _af_zip="$_tmp/vm/images/android-gapps.zip"
  printf 'cached\n' > "$_af_zip"

  _af_bin="$_tmp/bin"
  mkdir -p "$_af_bin"
  cat > "$_af_bin/adb" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *connect*) echo "connected"; exit 0 ;;
  *get-state*) echo "sideload"; exit 0 ;;
  *sideload*) exit 0 ;;
  *reboot*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_af_bin/adb"
  PATH="$_af_bin:$PATH"
  export PATH

  _af_curl_log="$_tmp/curl.log"
  cat > "$_af_bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl $*" >> "$_af_curl_log"
exit 0
EOF
  chmod +x "$_af_bin/curl"

  if ! vm_android_config Android 0 --gapps; then
    echo "FAIL: --gapps with cached zip should succeed"
    _failures=$((_failures + 1))
  fi
  if [ -f "$_af_curl_log" ]; then
    echo "FAIL: curl should not run when gapps zip is cached"
    _failures=$((_failures + 1))
  fi
}

test_adb_port_resolution
test_requires_at_least_one_flag
test_gapps_cached_zip_skips_download

if [ "$_failures" -gt 0 ]; then
  echo "android-config-tests: $_failures failure(s)"
  exit 1
fi
echo "android-config-tests: all passed"
