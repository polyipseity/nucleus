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

_afw_write_mock_adb() {
  _afw_mock_bin="$1"
  _afw_mock_log="$2"
  _afw_mock_ready="${3:-}"
  mkdir -p "$_afw_mock_bin"
  cat > "$_afw_mock_bin/adb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$_afw_mock_log"
  case "\$*" in
  disconnect*) exit 0 ;;
  reconnect*) exit 0 ;;
  connect*) exit 0 ;;
  *su\ -c\ id\ -u*) echo 0; exit 0 ;;
  *shell*echo\ 1*) echo 1; exit 0 ;;
  *base64*) ${4:-true} && touch "$_afw_mock_ready"; exit 0 ;;
  *show*wlan0*)
    if [ -z "$_afw_mock_ready" ] || [ -f "$_afw_mock_ready" ]; then
      echo "16: wlan0@wifi_eth: <BROADCAST,MULTICAST,UP>"
    fi
    exit 0
    ;;
  *shell*su\ -c*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$_afw_mock_bin/adb"
}

test_guest_setup_script_includes_virt_wifi_sequence() {
  _afw_script="$(vm_android_fake_wifi_guest_setup_script)"
  case "$_afw_script" in
    */vendor/lib/modules*) ;;
    *) echo "FAIL: guest setup should probe /vendor/lib/modules"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *modprobe\ -d*) ;;
    *) echo "FAIL: guest setup should use modprobe -d for GKI module paths"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *modprobe\ virt_wifi*) ;;
    *) echo "FAIL: guest setup should fall back to modprobe virt_wifi"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *type\ virt_wifi*) ;;
    *) echo "FAIL: guest setup should create wlan0 with type virt_wifi"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *wifi_eth*) ;;
    *) echo "FAIL: guest setup should rename ethernet to wifi_eth"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *connect-network\ VirtWifi\ open*) ;;
    *) echo "FAIL: guest setup should join the VirtWifi BSS"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *_apply_setup*) ;;
    *) echo "FAIL: guest setup should run full setup in a background subshell"; _failures=$((_failures + 1)) ;;
  esac
  case "$_afw_script" in
    *NUCLEUS_FAKE_WIFI_ASYNC*) ;;
    *) echo "FAIL: guest setup should support async link reconfiguration"; _failures=$((_failures + 1)) ;;
  esac
}

test_enable_runs_virt_wifi() {
  _afw_bin="$_tmp/bin"
  _afw_log="$_tmp/adb.log"
  _afw_ready="$_tmp/wlan0-ready"
  _afw_write_mock_adb "$_afw_bin" "$_afw_log" "$_afw_ready"
  PATH="$_afw_bin:$PATH"
  export PATH

  : > "$_afw_log"
  rm -f "$_afw_ready"
  if ! vm_android_fake_wifi_enable "localhost:22040"; then
    echo "FAIL: enable should succeed with mock adb"
    _failures=$((_failures + 1))
  fi
  assert_contains "$_afw_log" "base64" "enable runs guest setup via base64 pipe"
  assert_contains "$_afw_log" "nucleus-fake-wifi.sh" "enable persists service.d script"
}

test_revert_removes_service_script() {
  _afw_bin="$_tmp/bin2"
  _afw_log="$_tmp/adb2.log"
  _afw_write_mock_adb "$_afw_bin" "$_afw_log" ""
  PATH="$_afw_bin:$PATH"
  export PATH

  : > "$_afw_log"
  if ! vm_android_fake_wifi_revert "localhost:22040"; then
    echo "FAIL: revert should succeed with mock adb"
    _failures=$((_failures + 1))
  fi
  assert_contains "$_afw_log" "nucleus-fake-wifi.sh" "revert removes persist script"
  assert_contains "$_afw_log" "base64" "revert runs guest teardown via base64 pipe"
}

test_enable_skips_setup_when_wlan0_exists() {
  _afw_bin="$_tmp/bin3"
  _afw_log="$_tmp/adb3.log"
  _afw_write_mock_adb "$_afw_bin" "$_afw_log" "" "false"
  PATH="$_afw_bin:$PATH"
  export PATH

  : > "$_afw_log"
  if ! vm_android_fake_wifi_enable "localhost:22040"; then
    echo "FAIL: enable should succeed when wlan0 already exists"
    _failures=$((_failures + 1))
  fi
  if grep -Fq 'NUCLEUS_FAKE_WIFI_ASYNC=1' "$_afw_log"; then
    echo "FAIL: enable should not rerun async link setup when wlan0 already exists"
    _failures=$((_failures + 1))
  fi
}

test_guest_setup_script_includes_virt_wifi_sequence
test_enable_runs_virt_wifi
test_enable_skips_setup_when_wlan0_exists
test_revert_removes_service_script

if [ "$_failures" -gt 0 ]; then
  echo "android-fake-wifi-tests: $_failures failure(s)"
  exit 1
fi
echo "android-fake-wifi-tests: all passed"
