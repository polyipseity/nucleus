#!/usr/bin/env bash
# Unit tests for android-fake-wifi.sh enable/revert command generation.
#
# Run with: bash tests/scripts/android-fake-wifi-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/vms/android-fake-wifi.sh
. "$REPO_ROOT/src/scripts/vms/android-fake-wifi.sh"

_failures=0
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

assert_contains() {
  if ! grep -qF "$2" "$1"; then
    echo "FAIL: $3: expected log to contain '$2'"
    _failures=$((_failures + 1))
  fi
}

test_enable_runs_virt_wifi() {
  _afw_bin="$_tmp/bin"
  mkdir -p "$_afw_bin"
  _afw_log="$_tmp/adb.log"
  cat > "$_afw_bin/adb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$_afw_log"
case "\$*" in
  *shell*su\ -c*) exit 0 ;;
  *"ip link show wlan0"*) echo "3: wlan0: <BROADCAST,MULTICAST,UP>"; exit 0 ;;
  *modprobe*) exit 0 ;;
  *service.d*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_afw_bin/adb"
  PATH="$_afw_bin:$PATH"
  export PATH

  : > "$_afw_log"
  if ! vm_android_fake_wifi_enable "localhost:22040"; then
    echo "FAIL: enable should succeed with mock adb"
    _failures=$((_failures + 1))
  fi
  assert_contains "$_afw_log" "modprobe\ virt_wifi" "enable loads virt_wifi"
  assert_contains "$_afw_log" "ip\ link\ set\ wlan0\ up" "enable brings up wlan0"
}

test_revert_removes_service_script() {
  _afw_bin="$_tmp/bin2"
  mkdir -p "$_afw_bin"
  _afw_log="$_tmp/adb2.log"
  cat > "$_afw_bin/adb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$_afw_log"
case "\$*" in
  *shell*su\ -c*) exit 0 ;;
  *rm\ -f*) exit 0 ;;
  *wlan0\ down*) exit 0 ;;
  *rmmod*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_afw_bin/adb"
  PATH="$_afw_bin:$PATH"
  export PATH

  : > "$_afw_log"
  if ! vm_android_fake_wifi_revert "localhost:22040"; then
    echo "FAIL: revert should succeed with mock adb"
    _failures=$((_failures + 1))
  fi
  assert_contains "$_afw_log" "nucleus-fake-wifi.sh" "revert removes persist script"
  assert_contains "$_afw_log" "rmmod\ virt_wifi" "revert unloads virt_wifi via su"
}

test_enable_runs_virt_wifi
test_revert_removes_service_script

if [ "$_failures" -gt 0 ]; then
  echo "android-fake-wifi-tests: $_failures failure(s)"
  exit 1
fi
echo "android-fake-wifi-tests: all passed"
