#!/usr/bin/env bash
# Install and configure Magisk on the jqssun LineageOS Android guest (user build).
# Stages Magisk's boot_patch.sh kit from the APK, patches boot.img on the booted
# guest via ADB, flashes via fastboot, and installs the Magisk APK. Automation
# uses Magisk su on user builds.
#
# Usage: sourced by android-config.sh; not invoked directly.
set -euo pipefail

NUCLEUS_MAGISK_MARKER='android-magisk.tag.json'
NUCLEUS_MAGISK_PATCH_REMOTE='/data/local/tmp/nucleus-magisk-patch'
NUCLEUS_MAGISK_STOCK_BOOT_REMOTE='/data/local/tmp/nucleus-stock-boot.img'
NUCLEUS_ROOT_PROPS_SERVICE='/data/adb/service.d/nucleus-root-props.sh'

# vm_android_magisk_apk_lib_dir VM_INDEX
#   Magisk APK lib/ subdirectory for this guest CPU ABI.
vm_android_magisk_apk_lib_dir() {
  _amal_vm_index="$1"
  _amal_type="$(jq -r ".VMs[$_amal_vm_index].type" "$MANIFEST")"

  case "$(vm_derive_arch "$_amal_type")" in
    aarch64) printf 'arm64-v8a\n' ;;
    x86_64) printf 'x86_64\n' ;;
    arm) printf 'armeabi-v7a\n' ;;
    i386|x86) printf 'x86\n' ;;
    *)
      error "unsupported guest architecture for Magisk patching: $(vm_derive_arch "$_amal_type")"
      return 1
      ;;
  esac
}

# vm_android_enable_usb_debugging VM_INDEX
#   Enable Developer options and USB debugging via settings (booted system, via Magisk su).
vm_android_enable_usb_debugging() {
  _aeud_vm_index="$1"
  _aeud_serial="$(vm_android_adb_serial "$_aeud_vm_index")"

  if ! adb -s "$_aeud_serial" shell "su -c $(printf '%q' 'settings put global development_settings_enabled 1 && settings put global adb_enabled 1')"; then
    error "failed to enable Developer options and USB debugging via settings"
    return 1
  fi
  sleep 2
}

# vm_android_guest_has_magisk_su VM_INDEX
#   True when Magisk su is available on a booted guest.
vm_android_guest_has_magisk_su() {
  _agms_vm_index="$1"
  _agms_serial="$(vm_android_adb_serial "$_agms_vm_index")"

  if [ "$(vm_android_adb_poll_state "$_agms_vm_index")" != "device" ]; then
    return 1
  fi

  adb -s "$_agms_serial" shell 'su -c id -u' 2>/dev/null | tr -d '\r' | grep -qx '0'
}

# vm_android_su_getprop VM_INDEX NAME
#   Read a getprop value via Magisk su on a booted guest.
vm_android_su_getprop() {
  _asugp_vm_index="$1"
  _asugp_name="$2"
  _asugp_serial="$(vm_android_adb_serial "$_asugp_vm_index")"

  adb -s "$_asugp_serial" shell "su -c $(printf '%q' "getprop $_asugp_name")" 2>/dev/null | tr -d '\r\n'
}

# vm_android_root_props_boot_script
#   Guest Magisk service.d script that re-applies persist.sys.root_access each boot.
vm_android_root_props_boot_script() {
  cat <<'EOF'
#!/system/bin/sh
# persist.sys.root_access is already persist.*; rewrite is idempotent.
resetprop persist.sys.root_access 3
EOF
}

# vm_android_restore_ro_debuggable_user VM_INDEX
#   Repair ro.debuggable=1 left by a prior broken --root run (must stay 0 on user builds).
vm_android_restore_ro_debuggable_user() {
  _ardu_vm_index="$1"
  _ardu_serial="$(vm_android_adb_serial "$_ardu_vm_index")"
  _ardu_debuggable=''

  _ardu_debuggable="$(vm_android_su_getprop "$_ardu_vm_index" ro.debuggable)"
  if [ "$_ardu_debuggable" = '1' ]; then
    say "repairing ro.debuggable (was 1; restoring 0 for user build)..."
    if ! adb -s "$_ardu_serial" shell "su -c $(printf '%q' 'resetprop ro.debuggable 0')"; then
      error "failed to restore ro.debuggable to 0"
      return 1
    fi
  fi
}

# vm_android_verify_root_props_via_su VM_INDEX
#   Confirm persist.sys.root_access=3 and ro.debuggable=0 via Magisk su getprop.
vm_android_verify_root_props_via_su() {
  _avrps_vm_index="$1"
  _avrps_root_access=''
  _avrps_debuggable=''

  _avrps_root_access="$(vm_android_su_getprop "$_avrps_vm_index" persist.sys.root_access)"
  if [ "$_avrps_root_access" != '3' ]; then
    error "persist.sys.root_access is $_avrps_root_access (expected 3) after --root"
    return 1
  fi

  _avrps_debuggable="$(vm_android_su_getprop "$_avrps_vm_index" ro.debuggable)"
  if [ "$_avrps_debuggable" != '0' ]; then
    error "ro.debuggable is $_avrps_debuggable (expected 0) after --root; re-run --root to repair"
    return 1
  fi
}

# vm_android_smoke_test_dev_options VM_INDEX
#   Open Developer options and fail when Settings cannot set logd persist properties.
vm_android_smoke_test_dev_options() {
  _astdo_vm_index="$1"
  _astdo_serial="$(vm_android_adb_serial "$_astdo_vm_index")"

  # check-suppress:suppression_doc: Developer options activity may be unavailable on headless/recovery paths; logcat probe below is the real pass/fail signal.
  adb -s "$_astdo_serial" shell 'am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS' >/dev/null 2>&1 || true
  sleep 2
  if adb -s "$_astdo_serial" logcat -d -t 30 2>/dev/null | grep -q 'failed to set system property'; then
    error "Developer options smoke test failed (Settings property write error); ro.debuggable must stay 0"
    return 1
  fi
}

# vm_android_persist_root_props_service VM_INDEX
#   Install nucleus-root-props.sh under Magisk service.d.
vm_android_persist_root_props_service() {
  _aprps_vm_index="$1"
  _aprps_serial="$(vm_android_adb_serial "$_aprps_vm_index")"
  _aprps_persist_cmd="mkdir -p /data/adb/service.d && cat > $NUCLEUS_ROOT_PROPS_SERVICE <<'EOF'
$(vm_android_root_props_boot_script)
EOF
chmod 755 $NUCLEUS_ROOT_PROPS_SERVICE"

  if ! adb -s "$_aprps_serial" shell "su -c $(printf '%q' "$_aprps_persist_cmd")"; then
    error "failed to persist root props boot script at $NUCLEUS_ROOT_PROPS_SERVICE"
    return 1
  fi
}

# vm_android_config_root VM_INDEX
#   Enable dev options and Lineage persist.sys.root_access (Magisk su only).
vm_android_config_root() {
  _acr_vm_index="$1"
  _acr_serial="$(vm_android_adb_serial "$_acr_vm_index")"

  if ! vm_android_adb_wait_authorized "$_acr_vm_index" 600; then
    return 1
  fi

  if [ "$(vm_android_adb_poll_state "$_acr_vm_index")" != "device" ]; then
    error "rooted debugging requires booted system (adb state device), got: $(vm_android_adb_poll_state "$_acr_vm_index")"
    return 1
  fi

  if ! vm_android_guest_has_magisk_su "$_acr_vm_index"; then
    error "rooted debugging requires Magisk su; run --magisk first"
    return 1
  fi

  vm_android_restore_ro_debuggable_user "$_acr_vm_index" || return 1
  vm_android_enable_usb_debugging "$_acr_vm_index" || return 1

  if ! adb -s "$_acr_serial" shell "su -c $(printf '%q' 'resetprop persist.sys.root_access 3')"; then
    error "failed to apply persist.sys.root_access on guest"
    return 1
  fi

  vm_android_persist_root_props_service "$_acr_vm_index" || return 1
  vm_android_verify_root_props_via_su "$_acr_vm_index" || return 1

  if ! vm_android_guest_has_magisk_su "$_acr_vm_index"; then
    error "Magisk su not available after rooted debugging apply"
    return 1
  fi

  vm_android_smoke_test_dev_options "$_acr_vm_index" || return 1

  say "rooted debugging enabled on $_acr_serial (Magisk su, persist.sys.root_access=3); next: --fake-wifi"
}

# vm_android_download_boot_image VM_INDEX
#   Cache the jqssun boot image matching this guest architecture.
vm_android_download_boot_image() {
  _adbi_vm_index="$1"
  _adbi_suffix="$(vm_android_recovery_asset_suffix "$_adbi_vm_index")"
  _adbi_asset="boot_${_adbi_suffix}.img"
  _adbi_img="$(vm_src_path Android "$VM_ANDROID_BOOT_IMG")"
  _adbi_tag_file="$(vm_src_path Android "$VM_ANDROID_BOOT_TAG")"
  _adbi_dl_url="https://github.com/jqssun/android-lineage-qemu/releases/latest/download/$_adbi_asset"
  _adbi_tag=''

  _adbi_tag="$(vm_android_jqssun_release_tag_for_asset "$_adbi_asset")" || return 1

  if [ -f "$_adbi_img" ]; then
    _adbi_cached_tag=''
    if [ -f "$_adbi_tag_file" ]; then
      _adbi_cached_tag="$(jq -r '.tag_name // empty' "$_adbi_tag_file")"
    fi
    if [ "$_adbi_cached_tag" = "$_adbi_tag" ]; then
      say "using cached boot image: $_adbi_img" >&2
      printf '%s\n' "$_adbi_img"
      return 0
    fi
    say "jqssun release changed ($_adbi_cached_tag → $_adbi_tag); re-downloading boot image..." >&2
    rm -f "$_adbi_img"
  else
    say "downloading boot image ($_adbi_asset)..." >&2
  fi

  run_with_backoff "download boot image" \
    curl -fL -o "$_adbi_img" "$_adbi_dl_url" \
    || { error "failed to download boot image from $_adbi_dl_url"; return 1; }

  jq -n --arg tag "$_adbi_tag" '{tag_name: $tag}' > "$_adbi_tag_file"
  say "boot image ready: $_adbi_img" >&2
  printf '%s\n' "$_adbi_img"
}

# vm_android_download_magisk_apk VM_INDEX
#   Download and cache the Magisk APK from Android.magiskUrl in the manifest.
vm_android_download_magisk_apk() {
  _adma_vm_index="$1"
  _adma_url="$(jq -r ".VMs[$_adma_vm_index].Android.magiskUrl" "$MANIFEST")"
  _adma_apk="$(vm_src_path Android "$VM_ANDROID_MAGISK_APK")"

  if [ -z "$_adma_url" ] || [ "$_adma_url" = "null" ]; then
    error "Android.magiskUrl is not set in the manifest"
    return 1
  fi

  if [ -f "$_adma_apk" ]; then
    say "using cached Magisk APK: $_adma_apk" >&2
    printf '%s\n' "$_adma_apk"
    return 0
  fi

  say "downloading Magisk APK..." >&2
  run_with_backoff "download Magisk APK" \
    curl -fL -o "$_adma_apk" "$_adma_url" \
    || { error "failed to download Magisk from $_adma_url"; return 1; }
  say "Magisk APK ready: $_adma_apk" >&2
  printf '%s\n' "$_adma_apk"
}

# vm_android_magisk_stage_patch_kit MAGISK_APK VM_INDEX OUT_DIR
#   Extract Magisk boot_patch.sh and guest-native binaries from the APK zip layout.
vm_android_magisk_stage_patch_kit() {
  _amspk_apk="$1"
  _amspk_vm_index="$2"
  _amspk_out="$3"
  _amspk_lib="$(vm_android_magisk_apk_lib_dir "$_amspk_vm_index")" || return 1
  _amspk_lib_dir="$_amspk_out/lib/$_amspk_lib"

  require_command unzip

  rm -rf "$_amspk_out"
  mkdir -p "$_amspk_out"

  if ! unzip -qo "$_amspk_apk" \
    assets/boot_patch.sh \
    assets/util_functions.sh \
    assets/stub.apk \
    "lib/$_amspk_lib/libmagisk.so" \
    "lib/$_amspk_lib/libmagiskboot.so" \
    "lib/$_amspk_lib/libmagiskinit.so" \
    "lib/$_amspk_lib/libinit-ld.so" \
    -d "$_amspk_out"; then
    error "failed to extract Magisk patch kit from $_amspk_apk (lib/$_amspk_lib)"
    return 1
  fi

  if [ ! -f "$_amspk_out/assets/boot_patch.sh" ]; then
    error "Magisk APK is missing assets/boot_patch.sh ($_amspk_apk)"
    return 1
  fi

  mv "$_amspk_out/assets/boot_patch.sh" "$_amspk_out/boot_patch.sh"
  mv "$_amspk_out/assets/util_functions.sh" "$_amspk_out/util_functions.sh"
  mv "$_amspk_out/assets/stub.apk" "$_amspk_out/stub.apk"
  # check-suppress:suppression_doc: assets dir may already be gone after mv of boot_patch.sh and stub.apk.
  rmdir "$_amspk_out/assets" 2>/dev/null || true

  for _amspk_pair in \
    'libmagisk.so:magisk' \
    'libmagiskboot.so:magiskboot' \
    'libmagiskinit.so:magiskinit' \
    'libinit-ld.so:init-ld'; do
    _amspk_src_name="${_amspk_pair%%:*}"
    _amspk_dst_name="${_amspk_pair##*:}"
    if [ ! -f "$_amspk_lib_dir/$_amspk_src_name" ]; then
      error "Magisk APK is missing lib/$_amspk_lib/$_amspk_src_name"
      return 1
    fi
    cp -f "$_amspk_lib_dir/$_amspk_src_name" "$_amspk_out/$_amspk_dst_name"
    chmod 755 "$_amspk_out/$_amspk_dst_name"
  done

  rm -rf "${_amspk_out:?}/lib"
  chmod 755 "$_amspk_out/boot_patch.sh"
  chmod 644 "$_amspk_out/stub.apk"
}

# vm_android_magisk_guest_patch_boot VM_INDEX BOOT_IMG OUT_IMG MAGISK_APK
#   Patch boot.img on the booted guest using Magisk's boot_patch.sh (APK lib/*.so layout).
vm_android_magisk_guest_patch_boot() {
  _amgp_vm_index="$1"
  _amgp_boot="$2"
  _amgp_out="$3"
  _amgp_apk="$4"
  _amgp_serial="$(vm_android_adb_serial "$_amgp_vm_index")"
  _amgp_stage="$(vm_src_path Android "$VM_ANDROID_MAGISK_PATCH_KIT")"
  _amgp_remote_out="$NUCLEUS_MAGISK_PATCH_REMOTE/new-boot.img"

  vm_android_magisk_stage_patch_kit "$_amgp_apk" "$_amgp_vm_index" "$_amgp_stage" || return 1

  say "patching boot image with Magisk on guest $_amgp_serial..."
  adb -s "$_amgp_serial" shell "rm -rf $NUCLEUS_MAGISK_PATCH_REMOTE $NUCLEUS_MAGISK_STOCK_BOOT_REMOTE"
  adb -s "$_amgp_serial" push "$_amgp_stage/." "$NUCLEUS_MAGISK_PATCH_REMOTE/"
  adb -s "$_amgp_serial" push "$_amgp_boot" "$NUCLEUS_MAGISK_STOCK_BOOT_REMOTE"
  adb -s "$_amgp_serial" shell \
    "chmod 755 $NUCLEUS_MAGISK_PATCH_REMOTE/magisk $NUCLEUS_MAGISK_PATCH_REMOTE/magiskboot $NUCLEUS_MAGISK_PATCH_REMOTE/magiskinit $NUCLEUS_MAGISK_PATCH_REMOTE/init-ld $NUCLEUS_MAGISK_PATCH_REMOTE/boot_patch.sh"

  if ! adb -s "$_amgp_serial" shell \
    "cd $NUCLEUS_MAGISK_PATCH_REMOTE && BOOTMODE=true sh ./boot_patch.sh $NUCLEUS_MAGISK_STOCK_BOOT_REMOTE"; then
    error "Magisk boot_patch.sh failed on guest"
    return 1
  fi

  if ! adb -s "$_amgp_serial" pull "$_amgp_remote_out" "$_amgp_out"; then
    error "failed to pull patched boot image from guest (expected $_amgp_remote_out)"
    return 1
  fi

  # check-suppress:suppression_doc: remote cleanup is best-effort after a successful pull.
  adb -s "$_amgp_serial" shell "rm -rf $NUCLEUS_MAGISK_PATCH_REMOTE $NUCLEUS_MAGISK_STOCK_BOOT_REMOTE" 2>/dev/null || true
  say "patched boot image: $_amgp_out"
}

# vm_android_magisk_flash_boot VM_INDEX PATCHED_BOOT_IMG
#   Flash a Magisk-patched boot image via fastboot.
vm_android_magisk_flash_boot() {
  _amfb_vm_index="$1"
  _amfb_img="$2"
  _amfb_serial="$(vm_android_adb_serial "$_amfb_vm_index")"
  _amfb_fb_serial="$(vm_android_fastboot_serial "$_amfb_vm_index")"

  say "rebooting to fastboot on $_amfb_serial (VM: Recovery → Advanced → Enter fastboot if needed)..."
  # check-suppress:suppression_doc: reboot bootloader may fail when already in fastboot; fastboot_wait handles the next state.
  adb -s "$_amfb_serial" reboot bootloader 2>/dev/null || true

  if ! vm_android_fastboot_wait "$_amfb_vm_index" 180; then
    return 1
  fi

  if ! fastboot -s "$_amfb_fb_serial" flash boot "$_amfb_img"; then
    error "fastboot flash boot failed on $_amfb_fb_serial"
    return 1
  fi

  # check-suppress:suppression_doc: fastboot reboot after flash is best-effort; guest may already be rebooting.
  fastboot -s "$_amfb_fb_serial" reboot 2>/dev/null || true
  say "flashed Magisk boot image; waiting for system boot..."
}

# vm_android_magisk_install_apk VM_INDEX MAGISK_APK
#   Install the Magisk manager APK on a booted, authorized guest.
vm_android_magisk_install_apk() {
  _amia_vm_index="$1"
  _amia_apk="$2"
  _amia_serial="$(vm_android_adb_serial "$_amia_vm_index")"

  if ! vm_android_adb_wait_boot_completed "$_amia_vm_index" 600; then
    return 1
  fi

  say "installing Magisk APK on $_amia_serial..."
  _amia_attempt=0
  while [ "$_amia_attempt" -lt 12 ]; do
    if adb -s "$_amia_serial" install -r "$_amia_apk"; then
      return 0
    fi
    _amia_attempt=$((_amia_attempt + 1))
    if [ "$_amia_attempt" -lt 12 ]; then
      say "Magisk APK install not ready yet (guest may still be booting); retrying..."
      sleep 10
      # check-suppress:suppression_doc: guest may still be booting between Magisk APK install retries.
      vm_android_adb_wait_boot_completed "$_amia_vm_index" 120 || true
    fi
  done
  error "failed to install Magisk APK; tap Allow USB debugging and retry"
  return 1
}

# vm_android_install_adb_keys_via_su VM_INDEX PUBKEY_PATH
#   Install host adbkey.pub via Magisk su on a booted user build.
vm_android_install_adb_keys_via_su() {
  _aiakvs_vm_index="$1"
  _aiakvs_pubkey="$2"
  _aiakvs_serial="$(vm_android_adb_serial "$_aiakvs_vm_index")"
  _aiakvs_remote='/sdcard/nucleus-adbkey.pub'

  if ! vm_android_guest_has_magisk_su "$_aiakvs_vm_index"; then
    error "Magisk su is required to install adb_keys on a booted user build"
    return 1
  fi

  adb -s "$_aiakvs_serial" push "$_aiakvs_pubkey" "$_aiakvs_remote"
  adb -s "$_aiakvs_serial" shell "su -c $(printf '%q' "mkdir -p /data/misc/adb && cp $_aiakvs_remote /data/misc/adb/adb_keys && chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys && restorecon /data/misc/adb/adb_keys 2>/dev/null || chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys && rm -f $_aiakvs_remote && setprop ctl.restart adbd")"
}

# vm_android_install_adb_keys VM_INDEX PUBKEY_PATH
#   Push host adbkey.pub to /data/misc/adb/adb_keys with correct owner, mode, and SELinux context.
vm_android_install_adb_keys() {
  _aiak_vm_index="$1"
  _aiak_pubkey="$2"
  _aiak_serial="$(vm_android_adb_serial "$_aiak_vm_index")"

  adb -s "$_aiak_serial" push "$_aiak_pubkey" /data/misc/adb/adb_keys
  adb -s "$_aiak_serial" shell 'chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys'
  # check-suppress:suppression_doc: restorecon is unavailable on some recovery shells; chcon is the portable fallback.
  adb -s "$_aiak_serial" shell 'restorecon /data/misc/adb/adb_keys 2>/dev/null || chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys' 2>/dev/null || true
  # check-suppress:suppression_doc: best-effort adbd restart after adb_keys install; verified via authorized ADB probe.
  adb -s "$_aiak_serial" shell 'setprop ctl.restart adbd' 2>/dev/null || true
}

# vm_android_config_magisk VM_INDEX
#   Full Magisk install + configure pipeline for booted Lineage (jqssun user build).
vm_android_config_magisk() {
  _acm_vm_index="$1"
  _acm_serial="$(vm_android_adb_serial "$_acm_vm_index")"
  _acm_boot=''
  _acm_apk=''
  _acm_patched="$(vm_src_path Android "$VM_ANDROID_BOOT_MAGISK_PATCHED")"
  _acm_tag=''
  _acm_build=''

  if ! vm_android_adb_wait_authorized "$_acm_vm_index" 600; then
    return 1
  fi

  if [ "$(vm_android_adb_poll_state "$_acm_vm_index")" != "device" ]; then
    error "Magisk requires booted system (adb state device), got: $(vm_android_adb_poll_state "$_acm_vm_index")"
    return 1
  fi

  _acm_build="$(vm_android_shell_getprop "$_acm_vm_index" ro.build.display.id)"
  if printf '%s' "$_acm_build" | grep -qi 'gsi'; then
    error "Magisk install targets Lineage only (detected: $_acm_build); boot Lineage, not GSI"
    return 1
  fi

  if vm_android_guest_has_magisk_su "$_acm_vm_index"; then
    say "Magisk su is already available on $_acm_serial"
  else
    _acm_boot="$(vm_android_download_boot_image "$_acm_vm_index")" || return 1
    _acm_apk="$(vm_android_download_magisk_apk "$_acm_vm_index")" || return 1
    vm_android_magisk_guest_patch_boot "$_acm_vm_index" "$_acm_boot" "$_acm_patched" "$_acm_apk" || return 1
    vm_android_magisk_flash_boot "$_acm_vm_index" "$_acm_patched" || return 1

    if ! vm_android_adb_wait_boot_completed "$_acm_vm_index" 900; then
      error "timed out waiting for boot after Magisk flash; complete setup wizard and tap Allow USB debugging"
      return 1
    fi

    vm_android_magisk_install_apk "$_acm_vm_index" "$_acm_apk" || return 1
    say "next: open Magisk app on VM; complete environment-fix if prompted, then re-run --magisk"

    _acm_wait=0
    while [ "$_acm_wait" -lt 120 ]; do
      if vm_android_guest_has_magisk_su "$_acm_vm_index"; then
        break
      fi
      sleep 5
      _acm_wait=$((_acm_wait + 5))
    done

    if ! vm_android_guest_has_magisk_su "$_acm_vm_index"; then
      error "Magisk su not available; open Magisk app on VM, then retry --magisk"
      return 1
    fi
  fi

  _acm_tag=''
  _acm_tag="$(vm_android_jqssun_release_tag_for_asset "boot_$(vm_android_recovery_asset_suffix "$_acm_vm_index").img")" || _acm_tag=''
  if [ -n "$_acm_tag" ]; then
    jq -n --arg tag "$_acm_tag" '{tag_name: $tag, configured: true}' > "$(vm_src_path Android "$NUCLEUS_MAGISK_MARKER")"
  fi

  say "Magisk installed on $_acm_serial; next: --root"
}
