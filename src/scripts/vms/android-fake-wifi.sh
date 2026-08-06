#!/usr/bin/env bash
# Configure or revert fake Wi-Fi on an Android guest via the virt_wifi kernel module.
# Requires root (su) on the guest. Called by android-config.sh and nucleus-vm android-config.
#
# Usage: android-fake-wifi.sh enable|revert <adb-serial>
#
# Environment: none required beyond a working adb in PATH.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

NUCLEUS_FAKE_WIFI_SERVICE='/data/adb/service.d/nucleus-fake-wifi.sh'

usage() {
  usage_std "$(basename "$0")" "enable|revert <adb-serial>"
}

vm_android_fake_wifi_run_as_root() {
  _vafw_serial="$1"
  _vafw_cmd="$2"
  adb -s "$_vafw_serial" shell "su -c $(printf '%q' "$_vafw_cmd")"
}

vm_android_fake_wifi_enable() {
  _vafw_serial="$1"
  require_command adb

  say "loading virt_wifi and bringing up wlan0 on $_vafw_serial..."
  vm_android_fake_wifi_run_as_root "$_vafw_serial" 'modprobe virt_wifi && ip link set wlan0 up'
  if ! adb -s "$_vafw_serial" shell 'ip link show wlan0' 2>/dev/null | grep -q 'wlan0'; then
    error "wlan0 did not appear after modprobe virt_wifi; the kernel module may be missing"
    return 1
  fi

  _vafw_persist_cmd="mkdir -p /data/adb/service.d && cat > $NUCLEUS_FAKE_WIFI_SERVICE <<'EOF'
#!/system/bin/sh
modprobe virt_wifi
ip link set wlan0 up
EOF
chmod 755 $NUCLEUS_FAKE_WIFI_SERVICE"
  if vm_android_fake_wifi_run_as_root "$_vafw_serial" "$_vafw_persist_cmd" 2>/dev/null; then
    say "persisted fake Wi-Fi startup at $NUCLEUS_FAKE_WIFI_SERVICE"
  else
    warn "could not persist fake Wi-Fi script (Magisk service.d may be unavailable); re-run after reboot if needed"
  fi
  say "fake Wi-Fi enabled on $_vafw_serial"
}

vm_android_fake_wifi_revert() {
  _vafw_serial="$1"
  require_command adb

  say "reverting fake Wi-Fi on $_vafw_serial..."
  # check-suppress:suppression_doc: revert is best-effort; missing service file, wlan0, or module is acceptable.
  vm_android_fake_wifi_run_as_root "$_vafw_serial" "rm -f $NUCLEUS_FAKE_WIFI_SERVICE" 2>/dev/null || true
  # check-suppress:suppression_doc: wlan0 may already be down during revert.
  vm_android_fake_wifi_run_as_root "$_vafw_serial" 'ip link set wlan0 down' 2>/dev/null || true
  # check-suppress:suppression_doc: virt_wifi may already be unloaded during revert.
  vm_android_fake_wifi_run_as_root "$_vafw_serial" 'rmmod virt_wifi' 2>/dev/null || true
  say "fake Wi-Fi reverted on $_vafw_serial"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 2 ]; then
    usage >&2
    exit 1
  fi

  _action="$1"
  _serial="$2"

  case "$_action" in
    enable) vm_android_fake_wifi_enable "$_serial" ;;
    revert) vm_android_fake_wifi_revert "$_serial" ;;
    -h|--help) usage ;;
    *) error "unsupported action '$_action' (expected enable or revert)" ; usage >&2 ; exit 1 ;;
  esac
fi
