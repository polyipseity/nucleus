#!/usr/bin/env bash
# Post-provision Android guest configuration: MindTheGapps install, ADB key
# install, Lineage root, and fake Wi-Fi.
#
# Invoked by nucleus-vm android-config after vm_init sets MANIFEST, VM_DIR, IMAGES_DIR.
#
# Usage: android-config.sh <vm-name> <vm-index> [--gapps] [--adb-keys]
#        [--root] [--fake-wifi] [--fake-wifi-revert]
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
  --gapps               Download and install MindTheGapps on booted Lineage (requires authorized ADB).
  --adb-keys            Install host ~/.android/adbkey.pub into the guest adb_keys file.
  --root                Enable Lineage root for apps and adb (requires booted Lineage).
  --fake-wifi           Load virt_wifi and bring up wlan0 (requires root).
  --fake-wifi-revert    Remove persisted fake Wi-Fi and unload virt_wifi.
  -h|--help             Show usage.
EOF
}

vm_android_config_run_as_root() {
  _vacr_serial="$1"
  _vacr_cmd="$2"
  # check-suppress:suppression_doc: adb root is unavailable on user builds; su path below handles non-root adb.
  adb -s "$_vacr_serial" root 2>/dev/null || true
  sleep 2
  if adb -s "$_vacr_serial" shell 'id -u' 2>/dev/null | grep -qx '0'; then
    adb -s "$_vacr_serial" shell "$_vacr_cmd"
    return 0
  fi
  adb -s "$_vacr_serial" shell "su -c $(printf '%q' "$_vacr_cmd")"
}

vm_android_config_remount_rw() {
  _vacrr_serial="$1"
  if adb -s "$_vacrr_serial" remount 2>/dev/null; then
    return 0
  fi
  vm_android_config_run_as_root "$_vacrr_serial" 'mount -o rw,remount /'
}

vm_android_config_gapps() {
  _vacg_vm_index="$1"
  _vacg_serial="$(vm_android_adb_serial "$_vacg_vm_index")"
  _vacg_url="$(jq -r ".VMs[$_vacg_vm_index].Android.gappsUrl" "$MANIFEST")"
  _vacg_zip="$IMAGES_DIR/android-gapps.zip"
  _vacg_extract="$IMAGES_DIR/android-gapps-extract"
  _vacg_partition=''

  if [ -z "$_vacg_url" ] || [ "$_vacg_url" = "null" ]; then
    error "Android.gappsUrl is not set in the manifest"
    return 1
  fi

  if ! vm_android_adb_wait_authorized "$_vacg_vm_index" 600; then
    return 1
  fi

  if [ "$(vm_android_adb_list_state "$_vacg_vm_index")" != "device" ]; then
    error "MindTheGapps install requires booted Lineage (adb state device)"
    return 1
  fi

  if [ ! -f "$_vacg_zip" ]; then
    say "downloading MindTheGapps..."
    run_with_backoff "download MindTheGapps" \
      curl -fL -o "$_vacg_zip" "$_vacg_url" \
      || { error "failed to download MindTheGapps from $_vacg_url"; return 1; }
  else
    say "using cached MindTheGapps: $_vacg_zip"
  fi

  say "extracting MindTheGapps on host..."
  rm -rf "$_vacg_extract"
  mkdir -p "$_vacg_extract"
  run_cmd unzip -q -o "$_vacg_zip" -d "$_vacg_extract"

  say "remounting system partition read-write on $_vacg_serial..."
  vm_android_config_remount_rw "$_vacg_serial" || {
    error "failed to remount system read-write; enable root and retry"
    return 1
  }

  for _vacg_partition in system product system_ext; do
    if [ -d "$_vacg_extract/$_vacg_partition" ]; then
      say "pushing MindTheGapps $_vacg_partition/ to /$_vacg_partition/..."
      run_cmd adb -s "$_vacg_serial" push "$_vacg_extract/$_vacg_partition/." "/$_vacg_partition/"
    fi
  done

  if [ -d "$_vacg_extract/system_ext/priv-app/SetupWizard" ]; then
    say "removing stock Provision app (MindTheGapps ships SetupWizard)..."
    vm_android_config_run_as_root "$_vacg_serial" 'rm -rf /system/system_ext/priv-app/Provision'
  fi

  say "rebooting after MindTheGapps install..."
  # check-suppress:suppression_doc: reboot may fail if the guest is already shutting down; post-reboot wait handles the next state.
  adb -s "$_vacg_serial" reboot || true
  if ! vm_android_adb_wait_authorized "$_vacg_vm_index" 600; then
    error "guest did not return to authorized booted state after MindTheGapps install"
    return 1
  fi

  if ! adb -s "$_vacg_serial" shell 'pm list packages' 2>/dev/null | grep -q 'package:com.google.android.gms'; then
    error "MindTheGapps install finished but com.google.android.gms is not present"
    return 1
  fi
  say "MindTheGapps install complete on $_vacg_serial"
}

vm_android_config_adb_keys() {
  _vaca_vm_index="$1"
  _vaca_serial="$(vm_android_adb_serial "$_vaca_vm_index")"
  _vaca_pubkey="${HOME}/.android/adbkey.pub"

  if [ ! -f "$_vaca_pubkey" ]; then
    error "host ADB public key not found: $_vaca_pubkey (run adb once to generate keys)"
    return 1
  fi

  if ! vm_android_adb_wait_authorized "$_vaca_vm_index" 600; then
    return 1
  fi

  if [ "$(vm_android_adb_list_state "$_vaca_vm_index")" != "device" ]; then
    error "guest must be booted to system (adb state device), got: $(vm_android_adb_list_state "$_vaca_vm_index")"
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

  if ! vm_android_adb_wait_authorized "$_vacr_vm_index" 600; then
    return 1
  fi

  if [ "$(vm_android_adb_list_state "$_vacr_vm_index")" != "device" ]; then
    error "guest must be booted to Lineage (adb state device), got: $(vm_android_adb_list_state "$_vacr_vm_index")"
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

vm_android_config() {
  _vac_vm_name="$1"
  _vac_vm_index="$2"
  shift 2

  _vac_do_gapps=false
  _vac_do_adb_keys=false
  _vac_do_root=false
  _vac_do_fake_wifi=false
  _vac_do_fake_wifi_revert=false

  require_command adb
  require_command curl
  require_command unzip

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gapps) _vac_do_gapps=true ;;
      --adb-keys) _vac_do_adb_keys=true ;;
      --root) _vac_do_root=true ;;
      --fake-wifi) _vac_do_fake_wifi=true ;;
      --fake-wifi-revert) _vac_do_fake_wifi_revert=true ;;
      -h|--help) usage; return 0 ;;
      *) error "unsupported flag: $1" ; usage >&2 ; return 1 ;;
    esac
    shift
  done

  if [ "$_vac_do_gapps" = false ] && [ "$_vac_do_adb_keys" = false ] \
    && [ "$_vac_do_root" = false ] && [ "$_vac_do_fake_wifi" = false ] \
    && [ "$_vac_do_fake_wifi_revert" = false ]; then
    error "at least one of --gapps, --adb-keys, --root, --fake-wifi, or --fake-wifi-revert is required"
    usage >&2
    return 1
  fi

  _vac_serial="$(vm_android_adb_serial "$_vac_vm_index")"

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
    vm_android_adb_wait_authorized "$_vac_vm_index" 600 || { error "ADB not reachable for fake Wi-Fi"; return 1; }
    vm_android_fake_wifi_enable "$_vac_serial" || return 1
  fi
  if [ "$_vac_do_fake_wifi_revert" = true ]; then
    vm_android_adb_wait_authorized "$_vac_vm_index" 600 || { error "ADB not reachable for fake Wi-Fi revert"; return 1; }
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
