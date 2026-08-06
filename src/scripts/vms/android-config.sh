#!/usr/bin/env bash
# Post-provision Android guest configuration: recovery flash, MindTheGapps sideload,
# ADB key install, Lineage root, and fake Wi-Fi.
#
# Invoked by nucleus-vm android-config after vm_init sets MANIFEST, VM_DIR, IMAGES_DIR.
#
# Usage: android-config.sh <vm-name> <vm-index> [--recovery] [--gapps] [--adb-keys]
#        [--root] [--fake-wifi] [--fake-wifi-revert] [--all]
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/vm.sh
. "$SCRIPT_DIR/../lib/vm.sh"
# shellcheck source=android-fake-wifi.sh
. "$SCRIPT_DIR/android-fake-wifi.sh"

usage() {
  usage_std "$(basename "$0")" "<vm-name> <vm-index> [options]"
  cat <<'EOF'
  --recovery            Flash userdebug recovery from the latest jqssun release.
  --gapps               Download and sideload MindTheGapps (requires recovery/sideload).
  --adb-keys            Install host ~/.android/adbkey.pub into the guest adb_keys file.
  --root                Enable Lineage root for apps and adb (requires booted Lineage).
  --fake-wifi           Load virt_wifi and bring up wlan0 (requires root).
  --fake-wifi-revert    Remove persisted fake Wi-Fi and unload virt_wifi.
  --all                 Run recovery, then prompt for factory reset, gapps, adb-keys, root, fake-wifi.
  -h|--help             Show usage.
EOF
}

vm_android_config_recovery() {
  _vacr_vm_index="$1"
  _vacr_serial="$(vm_android_adb_serial "$_vacr_vm_index")"
  _vacr_fastboot="$(vm_android_fastboot_serial "$_vacr_vm_index")"
  _vacr_recovery=""

  if ! vm_android_adb_connect "$_vacr_vm_index" 60; then
    error "ADB not reachable on $_vacr_serial; start the VM first"
    return 1
  fi

  _vacr_recovery="$(vm_android_download_recovery)" || return 1

  say "rebooting to bootloader..."
  # check-suppress:suppression_doc: reboot may fail if the guest is already in bootloader; fastboot wait loop handles the next state.
  adb -s "$_vacr_serial" reboot bootloader || true
  sleep 10

  _vacr_elapsed=0
  while [ "$_vacr_elapsed" -lt 120 ]; do
    if fastboot -s "$_vacr_fastboot" devices 2>/dev/null | grep -q 'fastboot'; then
      break
    fi
    sleep 5
    _vacr_elapsed=$((_vacr_elapsed + 5))
  done

  if ! fastboot -s "$_vacr_fastboot" devices 2>/dev/null | grep -q 'fastboot'; then
    error "fastboot device not found at $_vacr_fastboot"
    return 1
  fi

  say "flashing recovery: $_vacr_recovery"
  run_cmd fastboot -s "$_vacr_fastboot" flash recovery "$_vacr_recovery"
  run_cmd fastboot -s "$_vacr_fastboot" reboot recovery
  say "recovery flashed; wait for recovery UI, then factory reset and reboot system (not GSI)"
}

vm_android_config_gapps() {
  _vacg_vm_index="$1"
  _vacg_serial="$(vm_android_adb_serial "$_vacg_vm_index")"
  _vacg_url="$(jq -r ".VMs[$_vacg_vm_index].Android.gappsUrl" "$MANIFEST")"
  _vacg_zip="$IMAGES_DIR/android-gapps.zip"

  if [ -z "$_vacg_url" ] || [ "$_vacg_url" = "null" ]; then
    error "Android.gappsUrl is not set in the manifest"
    return 1
  fi

  if ! vm_android_adb_connect "$_vacg_vm_index" 60; then
    error "ADB not reachable on $_vacg_serial"
    return 1
  fi

  _vacg_state="$(vm_android_adb_get_state "$_vacg_vm_index")"
  if [ "$_vacg_state" != "sideload" ] && [ "$_vacg_state" != "recovery" ]; then
    say "rebooting to sideload mode..."
    # check-suppress:suppression_doc: reboot may fail if the guest is already in sideload/recovery; connect retry loop handles the next state.
    adb -s "$_vacg_serial" reboot sideload || true
    if ! vm_android_adb_connect "$_vacg_vm_index" 120; then
      error "guest did not enter sideload mode; boot userdebug recovery and select Apply update from ADB"
      return 1
    fi
  fi

  if [ ! -f "$_vacg_zip" ]; then
    say "downloading MindTheGapps..."
    run_with_backoff "download MindTheGapps" \
      curl -fL -o "$_vacg_zip" "$_vacg_url" \
      || { error "failed to download MindTheGapps from $_vacg_url"; return 1; }
  else
    say "using cached MindTheGapps: $_vacg_zip"
  fi

  say "sideloading MindTheGapps..."
  run_cmd adb -s "$_vacg_serial" sideload "$_vacg_zip"
  say "MindTheGapps sideload complete; reboot system from recovery"
}

vm_android_config_adb_keys() {
  _vaca_vm_index="$1"
  _vaca_serial="$(vm_android_adb_serial "$_vaca_vm_index")"
  _vaca_pubkey="${HOME}/.android/adbkey.pub"

  if [ ! -f "$_vaca_pubkey" ]; then
    error "host ADB public key not found: $_vaca_pubkey (run adb once to generate keys)"
    return 1
  fi

  if ! vm_android_adb_connect "$_vaca_vm_index" 120; then
    error "ADB not reachable on $_vaca_serial"
    return 1
  fi

  _vaca_state="$(vm_android_adb_get_state "$_vaca_vm_index")"
  if [ "$_vaca_state" != "device" ]; then
    error "guest must be booted to system (adb state device), got: $_vaca_state"
    return 1
  fi

  # check-suppress:suppression_doc: adb root is unavailable on user builds; su path below handles non-root adb.
  adb -s "$_vaca_serial" root 2>/dev/null || true
  sleep 2

  if adb -s "$_vaca_serial" shell 'id -u' 2>/dev/null | grep -qx '0'; then
    adb -s "$_vaca_serial" push "$_vaca_pubkey" /data/misc/adb/adb_keys
    adb -s "$_vaca_serial" shell 'chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys'
  else
    adb -s "$_vaca_serial" push "$_vaca_pubkey" /sdcard/nucleus-adbkey.pub
    adb -s "$_vaca_serial" shell "su -c 'mkdir -p /data/misc/adb && cp /sdcard/nucleus-adbkey.pub /data/misc/adb/adb_keys && chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys && rm -f /sdcard/nucleus-adbkey.pub'"
  fi
  say "installed host ADB key on $_vaca_serial"
}

vm_android_config_root() {
  _vacr_vm_index="$1"
  _vacr_serial="$(vm_android_adb_serial "$_vacr_vm_index")"

  if ! vm_android_adb_connect "$_vacr_vm_index" 120; then
    error "ADB not reachable on $_vacr_serial"
    return 1
  fi

  _vacr_state="$(vm_android_adb_get_state "$_vacr_vm_index")"
  if [ "$_vacr_state" != "device" ]; then
    error "guest must be booted to Lineage (adb state device), got: $_vacr_state"
    return 1
  fi

  _vacr_build_key='display.id'
  _vacr_build="$(adb -s "$_vacr_serial" shell getprop "ro.build.${_vacr_build_key}" 2>/dev/null | tr -d '\r')"
  if printf '%s' "$_vacr_build" | grep -qi 'gsi'; then
    error "Lineage root is unavailable on Google GSI builds (detected: $_vacr_build); boot Lineage only"
    return 1
  fi

  adb -s "$_vacr_serial" shell 'settings put global adb_enabled 1'
  adb -s "$_vacr_serial" shell 'setprop persist.sys.root_access 3'
  # check-suppress:suppression_doc: adbd restart is best-effort; root access may already be active on Lineage.
  adb -s "$_vacr_serial" shell 'setprop ctl.restart adbd' 2>/dev/null || true
  say "enabled Lineage root (apps and adb) on $_vacr_serial"
}

vm_android_config_all() {
  _vaca_vm_name="$1"
  _vaca_vm_index="$2"

  vm_android_config_recovery "$_vaca_vm_index" || return 1
  say "manual step: in recovery, factory reset, then Reboot system now (do not boot GSI from vdc)"
  say "waiting for booted system (up to 10 minutes)..."
  if ! vm_android_adb_connect "$_vaca_vm_index" 600; then
    error "timed out waiting for booted Android system"
    return 1
  fi
  if [ "$(vm_android_adb_get_state "$_vaca_vm_index")" != "device" ]; then
    say "rebooting to sideload for MindTheGapps..."
  fi
  vm_android_config_gapps "$_vaca_vm_index" || return 1
  say "manual step: reboot system from recovery after sideload completes"
  say "waiting for booted system after GApps install..."
  if ! vm_android_adb_connect "$_vaca_vm_index" 600; then
    error "timed out waiting for booted Android system after GApps sideload"
    return 1
  fi
  vm_android_config_adb_keys "$_vaca_vm_index" || return 1
  vm_android_config_root "$_vaca_vm_index" || return 1
  vm_android_fake_wifi_enable "$(vm_android_adb_serial "$_vaca_vm_index")"
  say "android-config --all complete for '$_vaca_vm_name'"
}

vm_android_config() {
  _vac_vm_name="$1"
  _vac_vm_index="$2"
  shift 2

  _vac_do_recovery=false
  _vac_do_gapps=false
  _vac_do_adb_keys=false
  _vac_do_root=false
  _vac_do_fake_wifi=false
  _vac_do_fake_wifi_revert=false
  _vac_do_all=false

  require_command adb
  require_command fastboot
  require_command curl

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recovery) _vac_do_recovery=true ;;
      --gapps) _vac_do_gapps=true ;;
      --adb-keys) _vac_do_adb_keys=true ;;
      --root) _vac_do_root=true ;;
      --fake-wifi) _vac_do_fake_wifi=true ;;
      --fake-wifi-revert) _vac_do_fake_wifi_revert=true ;;
      --all) _vac_do_all=true ;;
      -h|--help) usage; return 0 ;;
      *) error "unsupported flag: $1" ; usage >&2 ; return 1 ;;
    esac
    shift
  done

  if [ "$_vac_do_all" = true ]; then
    say "running android-config --all for '$_vac_vm_name'..."
    vm_android_config_all "$_vac_vm_name" "$_vac_vm_index"
    return $?
  fi

  if [ "$_vac_do_recovery" = false ] && [ "$_vac_do_gapps" = false ] \
    && [ "$_vac_do_adb_keys" = false ] && [ "$_vac_do_root" = false ] \
    && [ "$_vac_do_fake_wifi" = false ] && [ "$_vac_do_fake_wifi_revert" = false ]; then
    error "at least one of --recovery, --gapps, --adb-keys, --root, --fake-wifi, --fake-wifi-revert, or --all is required"
    usage >&2
    return 1
  fi

  _vac_serial="$(vm_android_adb_serial "$_vac_vm_index")"

  if [ "$_vac_do_recovery" = true ]; then
    vm_android_config_recovery "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_gapps" = true ]; then
    vm_android_config_gapps "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_adb_keys" = true ]; then
    vm_android_config_adb_keys "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_root" = true ]; then
    vm_android_config_root "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_fake_wifi" = true ]; then
    vm_android_adb_connect "$_vac_vm_index" 120 || { error "ADB not reachable for fake Wi-Fi"; return 1; }
    vm_android_fake_wifi_enable "$_vac_serial" || return 1
  fi
  if [ "$_vac_do_fake_wifi_revert" = true ]; then
    vm_android_adb_connect "$_vac_vm_index" 120 || { error "ADB not reachable for fake Wi-Fi revert"; return 1; }
    vm_android_fake_wifi_revert "$_vac_serial" || return 1
  fi

  say "android-config complete for '$_vac_vm_name'"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 2 ]; then
    usage >&2
    exit 1
  fi
  _vac_entry_name="$1"
  _vac_entry_index="$2"
  shift 2
  vm_android_config "$_vac_entry_name" "$_vac_entry_index" "$@"
fi
