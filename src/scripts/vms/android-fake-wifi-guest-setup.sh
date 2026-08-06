#!/system/bin/sh
set -eu

# virt_wifi advertises an open BSS named VirtWifi; Android must associate or ADB stays offline.
_join_virt_wifi() {
  svc wifi enable 2>/dev/null || :
  cmd wifi set-wifi-enabled enabled 2>/dev/null || :
  sleep 1
  cmd wifi connect-network VirtWifi open 2>/dev/null \
    || cmd -w wifi connect-network VirtWifi open 2>/dev/null || :
  sleep 2
}

_apply_setup() {
  if ip link show wlan0 2>/dev/null | grep -q wlan0; then
    ip link set wlan0 up 2>/dev/null || :
    _join_virt_wifi
    return 0
  fi

  _modprobe_ok=0
  for _moddir in /vendor/lib/modules /odm/lib/modules /vendor_dlkm/lib/modules; do
    if [ -d "$_moddir" ] && modprobe -d "$_moddir" virt_wifi 2>/dev/null; then
      _modprobe_ok=1
      break
    fi
  done
  if [ "$_modprobe_ok" -eq 0 ]; then
    modprobe virt_wifi 2>/dev/null || :
  fi
  if [ ! -d /sys/module/virt_wifi ]; then
    echo "virt_wifi: module not loaded (checked /vendor/lib/modules, /odm/lib/modules, /vendor_dlkm/lib/modules)" >&2
    exit 1
  fi

  _eth=''
  for _iface in eth0 eth1; do
    if ip link show "$_iface" 2>/dev/null | grep -q "$_iface"; then
      _eth="$_iface"
      break
    fi
  done
  if [ -z "$_eth" ]; then
    _eth="$(ip -o link show 2>/dev/null | awk -F': ' '/: eth/ {print $2; exit}')"
  fi
  if [ -z "$_eth" ]; then
    echo "virt_wifi: no ethernet interface found" >&2
    exit 1
  fi

  ip link set "$_eth" down
  ip link set "$_eth" name wifi_eth
  ip link set wifi_eth up
  ip link add link wifi_eth name wlan0 type virt_wifi
  ip link set wlan0 up
  _join_virt_wifi
}

# Live enable via ADB must return before link changes: eth0 carries the forwarded ADB port.
if [ "${NUCLEUS_FAKE_WIFI_ASYNC:-0}" = "1" ]; then
  ( sleep 1; _apply_setup ) &
  exit 0
fi
_apply_setup
