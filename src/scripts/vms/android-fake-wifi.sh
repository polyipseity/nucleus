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
NUCLEUS_FAKE_WIFI_ADB_PROBE_S=3
NUCLEUS_FAKE_WIFI_ASYNC_KICKOFF_S=5
# Guest async: 1s delay + modprobe/link/join before ADB can recover.
NUCLEUS_FAKE_WIFI_ASYNC_GRACE_S=3

usage() {
  usage_std "$(basename "$0")" "enable|revert <adb-serial>"
}

# Guest script run under su to load virt_wifi and create wlan0 from the virtio ethernet NIC.
# Lineage virtio targets use eth0 only; rename it so ConnectivityService treats wlan0 as Wi-Fi.
vm_android_fake_wifi_guest_setup_script() {
  cat <<'EOF'
#!/system/bin/sh
set -eu

# virt_wifi advertises an open BSS named VirtWifi; Android must associate or ADB stays offline.
_join_virt_wifi() {
  svc wifi enable 2>/dev/null || true
  cmd wifi set-wifi-enabled enabled 2>/dev/null || true
  sleep 1
  cmd wifi connect-network VirtWifi open 2>/dev/null \
    || cmd -w wifi connect-network VirtWifi open 2>/dev/null || true
  sleep 2
}

_apply_setup() {
  if ip link show wlan0 2>/dev/null | grep -q wlan0; then
    ip link set wlan0 up 2>/dev/null || true
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
    modprobe virt_wifi 2>/dev/null || true
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
EOF
}

# Guest script run under su to tear down virt_wifi and restore eth0.
vm_android_fake_wifi_guest_revert_script() {
  cat <<'EOF'
#!/system/bin/sh
set -eu

_revert_links() {
  if ip link show wlan0 2>/dev/null | grep -q wlan0; then
    ip link set wlan0 down 2>/dev/null || true
    ip link delete wlan0 2>/dev/null || true
  fi
  if ip link show wifi_eth 2>/dev/null | grep -q wifi_eth; then
    ip link set wifi_eth down 2>/dev/null || true
    ip link set wifi_eth name eth0 2>/dev/null || true
    ip link set eth0 up 2>/dev/null || true
  fi
  if [ -d /sys/module/virt_wifi ]; then
    rmmod virt_wifi 2>/dev/null || true
  fi
}

if [ "${NUCLEUS_FAKE_WIFI_ASYNC:-0}" = "1" ]; then
  ( sleep 1; _revert_links ) &
  exit 0
fi
_revert_links
EOF
}

# TCP ADB can list "device" while shell hangs until disconnect+reconnect.
vm_android_fake_wifi_adb_reconnect() {
  _vafw_serial="$1"
  # check-suppress:suppression_doc: disconnect drops stale sessions; reconnect kicks the host-side transport.
  run_command_with_timeout 5 adb disconnect "$_vafw_serial" >/dev/null 2>&1 || true
  run_command_with_timeout 5 adb reconnect >/dev/null 2>&1 || true
  run_command_with_timeout 10 adb connect "$_vafw_serial" >/dev/null 2>&1 || true
}

vm_android_fake_wifi_adb_probe() {
  _vafw_serial="$1"
  run_command_with_timeout "$NUCLEUS_FAKE_WIFI_ADB_PROBE_S" adb -s "$_vafw_serial" shell 'su -c id -u' 2>/dev/null | tr -d '\r' | grep -qx '0'
}

vm_android_fake_wifi_adb_shell_probe() {
  _vafw_serial="$1"
  run_command_with_timeout "$NUCLEUS_FAKE_WIFI_ADB_PROBE_S" adb -s "$_vafw_serial" shell 'echo 1' 2>/dev/null | tr -d '\r' | grep -qxF '1'
}

# After link changes ADB drops; reconnect immediately instead of waiting on hung probes.
vm_android_fake_wifi_adb_ensure_after_link_change() {
  _vafw_serial="$1"
  vm_android_fake_wifi_adb_reconnect "$_vafw_serial"
  vm_android_fake_wifi_adb_probe "$_vafw_serial"
}

# Probe first; only disconnect+connect when the current session is dead.
vm_android_fake_wifi_adb_ensure() {
  _vafw_serial="$1"
  if vm_android_fake_wifi_adb_probe "$_vafw_serial"; then
    return 0
  fi
  if ! vm_android_fake_wifi_adb_shell_probe "$_vafw_serial"; then
    vm_android_fake_wifi_adb_reconnect "$_vafw_serial"
  fi
  vm_android_fake_wifi_adb_probe "$_vafw_serial"
}

vm_android_fake_wifi_require_su() {
  _vafw_serial="$1"
  if vm_android_fake_wifi_adb_probe "$_vafw_serial"; then
    return 0
  fi
  if vm_android_fake_wifi_adb_shell_probe "$_vafw_serial"; then
    error "Magisk su is not available on $_vafw_serial (adb shell works); open the Magisk app and retry"
  else
    error "ADB is not reachable on $_vafw_serial; run adb disconnect && adb connect manually, then retry"
  fi
  return 1
}

vm_android_fake_wifi_run_as_root() {
  _vafw_serial="$1"
  _vafw_cmd="$2"
  _vafw_timeout="${3:-30}"
  _vafw_attempt=0

  while [ "$_vafw_attempt" -lt 3 ]; do
    if run_command_with_timeout "$_vafw_timeout" adb -s "$_vafw_serial" shell "su -c $(printf '%q' "$_vafw_cmd")"; then
      return 0
    fi
    vm_android_fake_wifi_adb_reconnect "$_vafw_serial"
    _vafw_attempt=$((_vafw_attempt + 1))
  done
  return 1
}

# Run a multi-line guest script via su without fragile nested quoting.
# When ASYNC=true, set NUCLEUS_FAKE_WIFI_ASYNC=1 so link changes run in a guest
# background subshell (eth0 carries the forwarded ADB port).
vm_android_fake_wifi_run_guest_script() {
  _vafw_serial="$1"
  _vafw_script="$2"
  _vafw_async="${3:-false}"
  _vafw_b64="$(printf '%s' "$_vafw_script" | base64 | tr -d '\n')"
  _vafw_timeout=30
  if [ "$_vafw_async" = true ]; then
    _vafw_timeout=$NUCLEUS_FAKE_WIFI_ASYNC_KICKOFF_S
    vm_android_fake_wifi_run_as_root "$_vafw_serial" "NUCLEUS_FAKE_WIFI_ASYNC=1 echo $_vafw_b64 | base64 -d | sh" "$_vafw_timeout"
  else
    vm_android_fake_wifi_run_as_root "$_vafw_serial" "echo $_vafw_b64 | base64 -d | sh" "$_vafw_timeout"
  fi
}

# Poll only immediately after an async guest link change (not on idle reconnects).
vm_android_fake_wifi_wait_for_adb_after_async() {
  _vafw_serial="$1"
  _vafw_timeout="${2:-30}"
  _vafw_elapsed=0

  say "waiting for ADB on $_vafw_serial to recover (timeout ${_vafw_timeout}s)..."
  sleep "$NUCLEUS_FAKE_WIFI_ASYNC_GRACE_S"
  _vafw_elapsed=$NUCLEUS_FAKE_WIFI_ASYNC_GRACE_S
  while [ "$_vafw_elapsed" -lt "$_vafw_timeout" ]; do
    if vm_android_fake_wifi_adb_ensure_after_link_change "$_vafw_serial"; then
      return 0
    fi
    sleep 1
    _vafw_elapsed=$((_vafw_elapsed + 1))
  done
  return 1
}

vm_android_fake_wifi_wait_for_ready() {
  _vafw_serial="$1"
  _vafw_timeout="${2:-60}"
  _vafw_elapsed=0

  say "waiting for guest VirtWifi setup on $_vafw_serial (ADB reconnects after join; timeout ${_vafw_timeout}s)..."
  sleep "$NUCLEUS_FAKE_WIFI_ASYNC_GRACE_S"
  _vafw_elapsed=$NUCLEUS_FAKE_WIFI_ASYNC_GRACE_S
  while [ "$_vafw_elapsed" -lt "$_vafw_timeout" ]; do
    if vm_android_fake_wifi_adb_ensure_after_link_change "$_vafw_serial" \
      && vm_android_fake_wifi_wlan0_up "$_vafw_serial"; then
      return 0
    fi
    sleep 1
    _vafw_elapsed=$((_vafw_elapsed + 1))
  done
  return 1
}

vm_android_fake_wifi_print_diagnostics() {
  _vafw_serial="$1"
  say "fake Wi-Fi diagnostics for $_vafw_serial:"
  vm_android_fake_wifi_run_as_root "$_vafw_serial" \
    'uname -r; getprop ro.boot.wifi_impl; ls -la /lib/modules /vendor/lib/modules /vendor_dlkm/lib/modules 2>&1; find /vendor /odm /vendor_dlkm -name "virt_wifi*.ko" 2>/dev/null; zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_VIRT_WIFI|CONFIG_CFG80211" || true; ip link show' \
    2>/dev/null || warn "could not collect fake Wi-Fi diagnostics (is Magisk su available?)"
}

vm_android_fake_wifi_wlan0_up() {
  _vafw_serial="$1"
  run_command_with_timeout "$NUCLEUS_FAKE_WIFI_ADB_PROBE_S" adb -s "$_vafw_serial" shell "su -c $(printf '%q' 'ip link show wlan0')" 2>/dev/null | grep -q 'wlan0'
}

vm_android_fake_wifi_eth0_up() {
  _vafw_serial="$1"
  run_command_with_timeout "$NUCLEUS_FAKE_WIFI_ADB_PROBE_S" adb -s "$_vafw_serial" shell "su -c $(printf '%q' 'ip link show eth0')" 2>/dev/null | grep -q 'eth0'
}

vm_android_fake_wifi_enable() {
  _vafw_serial="$1"
  require_command adb

  if ! vm_android_fake_wifi_require_su "$_vafw_serial"; then
    return 1
  fi

  if vm_android_fake_wifi_wlan0_up "$_vafw_serial"; then
    say "wlan0 already present on $_vafw_serial (VirtWifi already joined)"
  else
    say "loading virt_wifi and creating wlan0 on $_vafw_serial (ADB will reconnect)..."
    if ! vm_android_fake_wifi_run_guest_script "$_vafw_serial" "$(vm_android_fake_wifi_guest_setup_script)" true; then
      vm_android_fake_wifi_print_diagnostics "$_vafw_serial"
      error "failed to start fake Wi-Fi setup on guest"
      return 1
    fi
    if ! vm_android_fake_wifi_wait_for_ready "$_vafw_serial" 60; then
      vm_android_fake_wifi_print_diagnostics "$_vafw_serial"
      error "ADB or wlan0 did not become ready after fake Wi-Fi setup"
      return 1
    fi
  fi

  _vafw_persist_cmd="mkdir -p /data/adb/service.d && cat > $NUCLEUS_FAKE_WIFI_SERVICE <<'EOF'
$(vm_android_fake_wifi_guest_setup_script)
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

  if ! vm_android_fake_wifi_require_su "$_vafw_serial"; then
    return 1
  fi

  say "reverting fake Wi-Fi on $_vafw_serial..."
  _vafw_had_wlan0=false
  if vm_android_fake_wifi_wlan0_up "$_vafw_serial"; then
    _vafw_had_wlan0=true
  fi

  # check-suppress:suppression_doc: revert is best-effort; missing service file is acceptable.
  vm_android_fake_wifi_run_as_root "$_vafw_serial" "rm -f $NUCLEUS_FAKE_WIFI_SERVICE" "$NUCLEUS_FAKE_WIFI_ASYNC_KICKOFF_S" 2>/dev/null || true

  if [ "$_vafw_had_wlan0" = true ]; then
    # check-suppress:suppression_doc: guest link teardown runs async; ADB drops briefly on eth0 rename.
    vm_android_fake_wifi_run_guest_script "$_vafw_serial" "$(vm_android_fake_wifi_guest_revert_script)" true 2>/dev/null || true
    if ! vm_android_fake_wifi_wait_for_adb_after_async "$_vafw_serial" 30; then
      warn "ADB did not recover within 30s after revert; if commands hang, run: adb disconnect $_vafw_serial && adb connect $_vafw_serial"
    fi
  elif vm_android_fake_wifi_eth0_up "$_vafw_serial"; then
    say "wlan0 already absent; eth0 is up on $_vafw_serial"
  fi

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
