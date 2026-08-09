#!/usr/bin/env bash
# Post-provision Android guest configuration: MindTheGapps sideload, ADB key
# install, Magisk root, and fake Wi-Fi.
#
# Invoked by nucleus-vm android-config after vm_init sets MANIFEST, VM_DIR, SRC_DIR.
#
# Usage: android-config.sh <vm-name> <vm-index> [--gapps] [--adb-keys]
#        [--magisk] [--root] [--fake-wifi] [--fake-wifi-revert]
set -euo pipefail

SCRIPT_DIR="${NUCLEUS_ANDROID_CONFIG_DIR:-}"
if [ -z "$SCRIPT_DIR" ]; then
  SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi
export NUCLEUS_ANDROID_CONFIG_DIR="$SCRIPT_DIR"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/vm.sh
. "$SCRIPT_DIR/../lib/vm.sh"
# shellcheck source=android-fake-wifi.sh
. "$SCRIPT_DIR/android-fake-wifi.sh"
# shellcheck source=android-magisk.sh
. "$SCRIPT_DIR/android-magisk.sh"

usage() {
  usage_std "$(basename "$0")" "<vm-name> <vm-index> [options]"
  cat <<'EOF'
  --gapps               Sideload MindTheGapps in recovery (requires userdebug recovery).
  --adb-keys            Install host ~/.android/adbkey.pub (recovery or booted system).
  --magisk              Install Magisk on booted Lineage (user build).
  --root                Enable rooted debugging on booted Lineage (requires --magisk).
  --fake-wifi           Create wlan0 via virt_wifi on eth0 (requires Magisk su).
  --fake-wifi-revert    Remove persisted fake Wi-Fi and restore eth0.
  -h|--help             Show usage.
EOF
}

vm_android_config_print_manual() {
  cat <<'EOF'
Android post-provision (jqssun LineageOS 23 user build)

Flags: --gapps --adb-keys --magisk --root --fake-wifi --fake-wifi-revert

--magisk installs Magisk su. --root enables Developer options and
persist.sys.root_access (ro.debuggable stays 0; Magisk su for automation). --fake-wifi needs Magisk su.

Recovery (GApps, optional ADB keys):
  1. nucleus-vm reset Android; start VM; boot LineageOS Recovery (factory-reset if needed).
  2. Recovery → Advanced → Enter fastboot.
  3. nucleus-vm android-config Android --gapps
  4. Recovery → Advanced → Enable ADB.
  5. Tap Install anyway when sideload asks about signature verification.
  6. Reboot system now.
  7. Optional: nucleus-vm android-config Android --adb-keys (skip if you will tap Allow on first boot).

Booted system:
  8. Finish setup wizard; enable USB debugging; tap Allow.
  9. nucleus-vm android-config Android --magisk
 10. Open Magisk app; complete environment-fix if prompted; re-run --magisk if needed.
 11. nucleus-vm android-config Android --root
 12. nucleus-vm android-config Android --fake-wifi
EOF
}

vm_android_config_gapps() {
  _vacg_vm_index="$1"
  _vacg_serial="$(vm_android_adb_serial "$_vacg_vm_index")"
  _vacg_url="$(jq -r ".VMs[$_vacg_vm_index].Android.gappsUrl" "$MANIFEST")"
  _vacg_zip="$(vm_src_path Android "$VM_ANDROID_GAPPS_ZIP")"
  _vacg_state=''

  if [ -z "$_vacg_url" ] || [ "$_vacg_url" = "null" ]; then
    error "Android.gappsUrl is not set in the manifest"
    return 1
  fi

  _vacg_state="$(vm_android_adb_poll_state "$_vacg_vm_index")"
  if [ "$_vacg_state" = "device" ]; then
    error "MindTheGapps requires LineageOS Recovery; guest is booted to system (device)"
    return 1
  fi

  vm_android_download_userdebug_recovery "$_vacg_vm_index" || return 1
  vm_android_ensure_userdebug_recovery "$_vacg_vm_index" || return 1

  if ! vm_android_adb_wait_recovery "$_vacg_vm_index" 300; then
    return 1
  fi

  if vm_android_adb_wait_sideload "$_vacg_vm_index" "${NUCLEUS_VM_ANDROID_SIDLELOAD_PROBE_TIMEOUT:-15}"; then
    say "guest already in sideload mode on $_vacg_serial"
  else
    _vacg_state="$(vm_android_adb_poll_state "$_vacg_vm_index")"
    if [ "$_vacg_state" = "recovery" ]; then
      say "entering sideload mode on $_vacg_serial..."
      # check-suppress:suppression_doc: reboot sideload may fail when already transitioning; sideload wait below handles the next state.
      adb -s "$_vacg_serial" reboot sideload 2>/dev/null || true
    fi
    if ! vm_android_adb_wait_sideload "$_vacg_vm_index" 120; then
      error "guest did not enter sideload mode; from recovery select Apply update from ADB"
      return 1
    fi
  fi

  if [ ! -f "$_vacg_zip" ]; then
    say "downloading MindTheGapps..."
    run_with_backoff "download MindTheGapps" \
      curl -fL -o "$_vacg_zip" "$_vacg_url" ||
      {
        error "failed to download MindTheGapps from $_vacg_url"
        return 1
      }
  else
    say "using cached MindTheGapps: $_vacg_zip"
  fi

  say "tap Install anyway on the VM if sideload asks about signature verification"
  say "sideloading MindTheGapps to $_vacg_serial..."
  if ! run_cmd adb -s "$_vacg_serial" sideload "$_vacg_zip"; then
    error "adb sideload failed; tap Install anyway on the VM if prompted, then retry"
    return 1
  fi

  say "MindTheGapps sideload finished"
  say "next: reboot system; then --magisk, --root, --fake-wifi"
}

vm_android_config_adb_keys() {
  _vaca_vm_index="$1"
  _vaca_serial="$(vm_android_adb_serial "$_vaca_vm_index")"
  _vaca_pubkey="${HOME}/.android/adbkey.pub"
  _vaca_state=''

  if [ ! -f "$_vaca_pubkey" ]; then
    error "host ADB public key not found: $_vaca_pubkey (run adb once to generate keys)"
    return 1
  fi

  _vaca_state="$(vm_android_adb_poll_state "$_vaca_vm_index")"
  case "$_vaca_state" in
  recovery | sideload)
    if ! vm_android_adb_wait_recovery "$_vaca_vm_index" 300; then
      return 1
    fi
    ;;
  device)
    if ! vm_android_adb_wait_authorized "$_vaca_vm_index" 600; then
      return 1
    fi
    ;;
  unauthorized)
    error "ADB unauthorized; enable ADB in recovery (Advanced → Enable ADB) or tap Allow on booted Lineage"
    return 1
    ;;
  *)
    error "ADB not reachable for key install (state: $_vaca_state)"
    return 1
    ;;
  esac

  _vaca_state="$(vm_android_adb_poll_state "$_vaca_vm_index")"
  case "$_vaca_state" in
  recovery | sideload)
    if ! vm_android_guest_shell_is_root "$_vaca_vm_index"; then
      error "recovery adb-keys requires root shell (Advanced → Enable ADB)"
      return 1
    fi
    vm_android_install_adb_keys "$_vaca_vm_index" "$_vaca_pubkey"
    ;;
  device)
    if ! vm_android_guest_has_magisk_su "$_vaca_vm_index"; then
      error "booted adb-keys requires Magisk su (run --magisk first) or recovery --adb-keys before first boot"
      return 1
    fi
    vm_android_install_adb_keys_via_su "$_vaca_vm_index" "$_vaca_pubkey"
    ;;
  *)
    error "guest must be in recovery or booted system for adb-keys; current state: $_vaca_state"
    return 1
    ;;
  esac
  say "installed host ADB key on $_vaca_serial ($_vaca_state)"
  case "$_vaca_state" in
  recovery | sideload) say "next: reboot system, then --magisk, --root, --fake-wifi" ;;
  esac
}

vm_android_config() {
  _vac_vm_id="$1"
  _vac_vm_index="$2"
  shift 2

  _vac_do_gapps=false
  _vac_do_adb_keys=false
  _vac_do_magisk=false
  _vac_do_root=false
  _vac_do_fake_wifi=false
  _vac_do_fake_wifi_revert=false

  require_command adb
  require_command curl
  require_command fastboot
  require_command unzip

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --gapps) _vac_do_gapps=true ;;
    --adb-keys) _vac_do_adb_keys=true ;;
    --adb-debug)
      error "unknown flag: --adb-debug (did you mean --adb-keys?)"
      usage >&2
      return 1
      ;;
    --root) _vac_do_root=true ;;
    --magisk) _vac_do_magisk=true ;;
    --fake-wifi) _vac_do_fake_wifi=true ;;
    --fake-wifi-revert) _vac_do_fake_wifi_revert=true ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      error "unsupported flag: $1"
      usage >&2
      return 1
      ;;
    esac
    shift
  done

  if [ "$_vac_do_gapps" = false ] && [ "$_vac_do_adb_keys" = false ] &&
    [ "$_vac_do_magisk" = false ] && [ "$_vac_do_root" = false ] &&
    [ "$_vac_do_fake_wifi" = false ] &&
    [ "$_vac_do_fake_wifi_revert" = false ]; then
    vm_android_config_print_manual
    return 0
  fi

  _vac_serial="$(vm_android_adb_serial "$_vac_vm_index")"

  if [ "$_vac_do_gapps" = true ]; then
    vm_android_config_gapps "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_adb_keys" = true ]; then
    vm_android_config_adb_keys "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_magisk" = true ]; then
    vm_android_config_magisk "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_root" = true ]; then
    vm_android_config_root "$_vac_vm_index" || return 1
  fi
  if [ "$_vac_do_fake_wifi" = true ]; then
    vm_android_adb_wait_authorized "$_vac_vm_index" 600 || {
      error "fake Wi-Fi requires booted Lineage with authorized ADB"
      return 1
    }
    if ! vm_android_guest_has_magisk_su "$_vac_vm_index"; then
      error "fake Wi-Fi requires Magisk su; run --magisk first"
      return 1
    fi
    vm_android_fake_wifi_enable "$_vac_serial" || return 1
  fi
  if [ "$_vac_do_fake_wifi_revert" = true ]; then
    vm_android_adb_wait_authorized "$_vac_vm_index" 600 || {
      error "fake Wi-Fi revert requires booted Lineage with authorized ADB"
      return 1
    }
    vm_android_fake_wifi_revert "$_vac_serial" || return 1
  fi

  say "android-config complete for '$_vac_vm_id'"
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
