#!/system/bin/sh
set -eu

_revert_links() {
  if ip link show wlan0 2>/dev/null | grep -q wlan0; then
    ip link set wlan0 down 2>/dev/null || :
    ip link delete wlan0 2>/dev/null || :
  fi
  if ip link show wifi_eth 2>/dev/null | grep -q wifi_eth; then
    ip link set wifi_eth down 2>/dev/null || :
    ip link set wifi_eth name eth0 2>/dev/null || :
    ip link set eth0 up 2>/dev/null || :
  fi
  if [ -d /sys/module/virt_wifi ]; then
    rmmod virt_wifi 2>/dev/null || :
  fi
}

if [ "${NUCLEUS_FAKE_WIFI_ASYNC:-0}" = "1" ]; then
  (
    sleep 1
    _revert_links
  ) &
  exit 0
fi
_revert_links
