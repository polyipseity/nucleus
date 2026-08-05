# shellcheck shell=bash
# Source this file from the vm-setup dispatcher, then call vm_init with
# all config values as positional parameters to make data flow explicit.
# Example:
#   . "$SCRIPT_DIR/vm.sh"
#   vm_init "$REPO_ROOT" "$VM_DIR" ...
#
# HARD PROHIBITION: ALL variables used by this library MUST be initialized
# via vm_init(). Do NOT rely on variables set by the sourcing script — that
# is implicit data passing. It produces untraceable, unscoped dependencies
# that shellcheck cannot verify. If SC2153 fires, it means a variable was
# used without being declared in vm_init(). The ONLY correct fix is to add
# it to vm_init() and pass it from the caller. Suppressing SC2153 is
# FORBIDDEN — it hides the violation.

# vm_init — Initialize all shared config variables from explicit
# positional parameters. Called after sourcing so shellcheck can trace every
# variable assignment through the function call.
vm_init() {
  REPO_ROOT="$1"
  VM_DIR="$2"
  IMAGES_DIR="$3"
  TEMPLATES_DIR="$4"
  dry_run="$5"
  windows_iso="$6"
  windows_iso_source="$7"
  windows_iso_retries="$8"
  windows_headless="$9"
  accelerator="${10}"
  vm_secret_owner="${11}"
  vm_guest_username="${12}"
  vm_guest_password="${13}"
  vm_guest_credentials_fingerprint="${14}"
  NUCLEUS_MIDO_PATCH_FILE="${15}"
  NUCLEUS_MIDO_SCRIPT="${16}"
  accept_gsi_license="${17}"
  upgrade_android="${18}"
  reset_userdata="${19}"
  VMS_DIR="${20}"
  MANIFEST="${21}"
  NUCLEUS_HOST="${22}"
  gc_disabled_mode="${23}"
}

# write_vm_directory_readme
#   Writes a cross-host usage guide into the managed VM directory so operators
#   can transfer VM artifacts between hosts and run guest-specific converge
#   commands without relying on generated helper scripts.
write_vm_directory_readme() {
  _wvdr_readme="$VM_DIR/README.md"
  if [ "$dry_run" = true ]; then
    dry_run "write VM directory guide: $_wvdr_readme"
    return 0
  fi

  _wvdr_vm_dir_short="$HOME/virtual machines"
  _wvdr_images_dir_short="$HOME/virtual machines/images"
  if [ -f "$TEMPLATES_DIR/README.md" ]; then
    sed -e "s|__VM_DIR_DISPLAY__|$_wvdr_vm_dir_short|g" \
        -e "s|__IMAGES_DIR_DISPLAY__|$_wvdr_images_dir_short|g" \
        "$TEMPLATES_DIR/README.md" >"$_wvdr_readme"
    say "wrote VM directory guide: $_wvdr_readme (template)"
  else
    warn "README template not found at $TEMPLATES_DIR/README.md; writing minimal guide"
    {
      printf '# virtual machines\n\n'
      # shellcheck disable=SC2016 # reason: single quotes intentional — backticks must not expand
      printf 'This directory stores VM artifacts managed by `nucleus-vm`.\n'
    } >"$_wvdr_readme"
  fi
}

# ensure_utm_default_vm_location
#   Best-effort default-location wiring for UTM by linking the sandboxed
#   Documents root to the managed ~/virtual machines directory when safe.
ensure_utm_default_vm_location() {
  _eudvl_utm_docs="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

  if [ -L "$_eudvl_utm_docs" ]; then
    # check-suppress:suppression_doc: symlink may not exist yet; readlink exits 1 for broken/missing links.
    _eudvl_target="$(readlink "$_eudvl_utm_docs" 2>/dev/null || true)"
    if [ "$_eudvl_target" = "$VM_DIR" ]; then
      say "UTM default VM location already points to $VM_DIR"
    else
      warn "$_eudvl_utm_docs is a symlink to $_eudvl_target; expected $VM_DIR"
    fi
    return 0
  fi

  if [ -d "$_eudvl_utm_docs" ]; then
    # WHY: preserve existing user-managed UTM document stores; only replace an
    # empty directory to avoid destructive moves.
    if [ -n "$(find "$_eudvl_utm_docs" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      warn "$_eudvl_utm_docs is non-empty; cannot auto-link to $VM_DIR"
      return 0
    fi
    rmdir "$_eudvl_utm_docs"
  fi

  ln -s "$VM_DIR" "$_eudvl_utm_docs"
  say "linked UTM default VM location: $_eudvl_utm_docs -> $VM_DIR"
}

# ensure_tart_vm_dir
#   Co-locates Tart's VM store inside the managed ~/virtual machines directory
#   by symlinking ~/.tart → ~/virtual machines/.tart so Tart artifacts (VMs and
#   OCI cache) stay alongside UTM bundles in one tree for unified backup.
#   Only runs on Darwin; Tart uses Apple's Virtualization.framework.
ensure_tart_vm_dir() {
  _etd_target="$VM_DIR/.tart"
  _etd_default="$HOME/.tart"

  mkdir -p "$_etd_target"

  if [ -L "$_etd_default" ]; then
    # check-suppress:suppression_doc: symlink may not exist yet; readlink exits 1 for broken/missing links.
    _etd_current="$(readlink "$_etd_default" 2>/dev/null || true)"
    if [ "$_etd_current" = "$_etd_target" ]; then
      say "tart storage already linked: $_etd_default -> $_etd_target"
    else
      warn "$_etd_default is a symlink to $_etd_current (expected $_etd_target); not relinking"
    fi
    return 0
  fi

  if [ -d "$_etd_default" ]; then
    # WHY: migrate existing ~/.tart to VM_DIR on first run so existing VMs are
    # not lost when this policy was introduced.
    # Use rsync --no-specials to skip Unix socket files (e.g. control.sock)
    # which cp -a cannot copy and which are not persistent data.
    say "migrating ~/.tart to $_etd_target..."
    rsync -a --no-specials --no-devices "$_etd_default/" "$_etd_target/"
    rm -rf "$_etd_default"
  fi

  ln -s "$_etd_target" "$_etd_default"
  say "linked tart storage: $_etd_default -> $_etd_target"
}

# should_include_host HOSTS_JSON — returns 0 if the VM should run on the
# current host.  HOSTS_JSON is the raw JSON value of the VM's "hosts" field
# (a string array of host names).  A VM whose hosts list omits the current
# host is excluded.
should_include_host() {
  _sjh_json="$1"
  printf '%s' "$_sjh_json" | jq -e --arg host "$NUCLEUS_HOST" 'contains([$host])' >/dev/null 2>&1
}

# Helpers

run_cmd() {
  if [ "$dry_run" = true ]; then
    dry_run "$*"
  else
    "$@"
  fi
}

# validate_qcow2_image PATH LABEL MIN_VIRTUAL_SIZE
#   Verifies that a QCOW2 image exists, is non-empty, and (when qemu-img is
#   available) reports format=qcow2 with a sensible virtual size.  The
#   minimum virtual size must be passed explicitly from the manifest
#   minImageSize so every call site applies the VM's declared floor.
validate_qcow2_image() {
  _vqi_path="$1"
  _vqi_label="$2"
  _vqi_min_size="$3"

  if [ ! -f "$_vqi_path" ]; then
    error "$_vqi_label not found: $_vqi_path"
    return 1
  fi

  _vqi_size_bytes="$(wc -c < "$_vqi_path" | tr -d '[:space:]')"
  if [ -z "$_vqi_size_bytes" ] || [ "$_vqi_size_bytes" -le 0 ]; then
    error "$_vqi_label is empty or unreadable: $_vqi_path"
    return 1
  fi

  if command -v qemu-img >/dev/null 2>&1; then
    # check-suppress:suppression_doc: image file may not exist; probe expected to fail.
  _vqi_info="$(qemu-img info --output=json "$_vqi_path" 2>/dev/null || true)"
    if [ -z "$_vqi_info" ]; then
      error "qemu-img could not read $_vqi_label: $_vqi_path"
      return 1
    fi

    _vqi_format="$(printf '%s' "$_vqi_info" | jq -r '.format // empty')"
    if [ "$_vqi_format" != 'qcow2' ]; then
      error "$_vqi_label has unexpected format '$_vqi_format' (expected qcow2): $_vqi_path"
      return 1
    fi

    _vqi_virtual_size="$(printf '%s' "$_vqi_info" | jq -r '."virtual-size" // 0')"
    if [ -z "$_vqi_virtual_size" ] || [ "$_vqi_virtual_size" -lt "$_vqi_min_size" ]; then
      error "$_vqi_label virtual size is too small ($_vqi_virtual_size bytes; minimum $_vqi_min_size): $_vqi_path"
      return 1
    fi
  fi

  return 0
}

# vm_guest_credentials_marker_path NAME [DISK_PATH]
#   Returns the sidecar marker path storing the guest-credential fingerprint
#   used when building/provisioning the VM image or runtime disk.
vm_guest_credentials_marker_path() {
  _vgcm_name="$1"
  _vgcm_disk_path="${2:-}"
  if [ -n "$_vgcm_disk_path" ]; then
    printf '%s.vm-guest-credentials-sha256\n' "$_vgcm_disk_path"
  else
    printf '%s/%s.vm-guest-credentials-sha256\n' "$IMAGES_DIR" "$_vgcm_name"
  fi
}

# vm_guest_credentials_marker_matches EXPECTED_FINGERPRINT MARKER_PATH
#   Returns 0 when MARKER_PATH exists and equals EXPECTED.
vm_guest_credentials_marker_matches() {
  _vgcm_expected="$1"
  _vgcm_marker="$2"
  if [ ! -f "$_vgcm_marker" ]; then
    return 1
  fi
  _vgcm_actual="$(tr -d '\r\n' <"$_vgcm_marker")"
  [ "$_vgcm_actual" = "$_vgcm_expected" ]
}

# vm_sha256_input
#   Prints the SHA-256 fingerprint of stdin using the first available tool:
#   sha256sum -> shasum -a 256 -> openssl dgst -sha256.  WHY: macOS ships
#   shasum/openssl but not sha256sum, and each tool's output format differs
#   (hence the awk column).  Returns 1 when no SHA-256 tool is available.
vm_sha256_input() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
    return 0
  fi

  error "no SHA-256 tool is available; cannot fingerprint VM guest state"
  return 1
}

# vm_guest_config_marker_path NAME [DISK_PATH]
#   Returns the sidecar marker path storing the guest-config fingerprint
#   (NixOS guest.nix + imports + flake.lock) for drift detection.
vm_guest_config_marker_path() {
  _vgcmp_name="$1"
  _vgcmp_disk_path="${2:-}"
  if [ -n "$_vgcmp_disk_path" ]; then
    printf '%s.vm-guest-config-sha256\n' "$_vgcmp_disk_path"
  else
    printf '%s/%s.vm-guest-config-sha256\n' "$IMAGES_DIR" "$_vgcmp_name"
  fi
}

# vm_guest_config_marker_matches EXPECTED_FINGERPRINT MARKER_PATH
#   Returns 0 when MARKER_PATH exists and equals EXPECTED.
vm_guest_config_marker_matches() {
  _vgcmm_expected="$1"
  _vgcmm_marker="$2"
  if [ ! -f "$_vgcmm_marker" ]; then
    return 1
  fi
  _vgcmm_actual="$(tr -d '\r\n' <"$_vgcmm_marker")"
  [ "$_vgcmm_actual" = "$_vgcmm_expected" ]
}

# vm_guest_config_fingerprint
#   Prints a SHA-256 fingerprint of the NixOS guest configuration: the resolved
#   paths of every src/ import in guest.nix plus src/flake.lock.  WHY: the
#   imported files are leaf modules (no transitive imports), so resolving the
#   import list captures all configuration source; flake.lock pins the
#   nixos-generators revision.  Returns 1 when no SHA-256 tool is available.
vm_guest_config_fingerprint() {
  _gcf_imports="$(grep -oE '(\.\./)+src/[A-Za-z0-9_./-]+\.nix' "$VMS_DIR/nixos/guest.nix" | sort -u)"
  {
    printf '%s\n' "$_gcf_imports"
    if [ -f "$REPO_ROOT/src/flake.lock" ]; then
      cat "$REPO_ROOT/src/flake.lock"
    fi
  } | vm_sha256_input
}

# wait_for_utm_registration NAME
#   Polls utmctl list until VM NAME appears or timeout is reached.
wait_for_utm_registration() {
  _wfur_name="$1"
  _wfur_attempt=1
  _wfur_max_attempts=15

  while [ "$_wfur_attempt" -le "$_wfur_max_attempts" ]; do
    if "$UTMCTL" list | awk 'NR > 1 { print $3 }' | grep -qxF "$_wfur_name"; then
      return 0
    fi
    sleep 1
    _wfur_attempt=$((_wfur_attempt + 1))
  done

  return 1
}

# run_with_backoff LABEL COMMAND [ARG...]
# Args:
#   $1 — human-readable operation label
#   $2.. — command and arguments to execute
# Retries failed network operations with exponential backoff when
# --windows-iso-retries is greater than 0.
run_with_backoff() {
  _rwb_label="$1"
  shift
  _rwb_attempt=1
  _rwb_max=$((windows_iso_retries + 1))

  while [ "$_rwb_attempt" -le "$_rwb_max" ]; do
    if "$@"; then
      return 0
    fi
    _rwb_status=$?

    if [ "$_rwb_attempt" -ge "$_rwb_max" ]; then
      return "$_rwb_status"
    fi

    _rwb_sleep=1
    _rwb_i=1
    while [ "$_rwb_i" -lt "$_rwb_attempt" ]; do
      _rwb_sleep=$((_rwb_sleep * 2))
      _rwb_i=$((_rwb_i + 1))
    done
    if [ "$_rwb_sleep" -gt 30 ]; then
      _rwb_sleep=30
    fi

    warn "$_rwb_label failed (attempt $_rwb_attempt/$_rwb_max); retrying in ${_rwb_sleep}s"
    sleep "$_rwb_sleep"
    _rwb_attempt=$((_rwb_attempt + 1))
  done

  return 1
}

# Wait for a guest to become reachable via QEMU GA or SSH.
# Returns 0 if guest is ready, 1 on timeout.
vm_wait_for_guest() {
  _wg_name="$1"
  _wg_type="$2"
  _wg_timeout="${3:-150}"
  _wg_elapsed=0

  # Probe host ports come from the manifest portForwards, not hard-coded
  # 2222/5555 values: guest 22 -> SSH, guest 5555 -> ADB.  The Windows QEMU
  # GA pipe path below is host-kind based and involves no host port.
  _wg_ssh_port="$(jq -r --arg t "$_wg_type" '[.VMs[] | select(.type == $t) | .portForwards[] | select(.guestPort == 22)][0].hostPort // empty' "$MANIFEST")"
  _wg_adb_port="$(jq -r --arg t "$_wg_type" '[.VMs[] | select(.type == $t) | .portForwards[] | select(.guestPort == 5555)][0].hostPort // empty' "$MANIFEST")"

  if [ "$_wg_type" = "NixOS" ]; then
    # Try QEMU GA via socat first
    if command -v socat >/dev/null 2>&1; then
      while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
        echo '{"execute":"guest-ping"}' | socat - "PIPE:\\\\.\\pipe\\qga-$_wg_name" 2>/dev/null && return 0
        sleep 5
        _wg_elapsed=$((_wg_elapsed + 5))
      done
    fi
    # Fallback: SSH
    while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$_wg_ssh_port" "$_wg_name@localhost" true 2>/dev/null && return 0
      sleep 5
      _wg_elapsed=$((_wg_elapsed + 5))
    done
    return 1
  elif [ "$_wg_type" = "Windows" ]; then
    # QEMU GA via socat
    if command -v socat >/dev/null 2>&1; then
      while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
        echo '{"execute":"guest-ping"}' | socat - "PIPE:\\\\.\\pipe\\qga-$_wg_name" 2>/dev/null && return 0
        sleep 5
        _wg_elapsed=$((_wg_elapsed + 5))
      done
    fi
    return 1
  elif [ "$_wg_type" = "Android" ]; then
    # ADB connection check (Android guests expose ADB on the manifest
    # forwarded host port for guest 5555)
    if command -v adb >/dev/null 2>&1; then
      while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
        if adb connect "localhost:$_wg_adb_port" 2>/dev/null | grep -q 'connected'; then
          return 0
        fi
        sleep 5
        _wg_elapsed=$((_wg_elapsed + 5))
      done
    fi
    # Fallback: SSH on the same host port as ADB
    _wg_elapsed=0
    while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$_wg_adb_port" "root@localhost" true 2>/dev/null && return 0
      sleep 5
      _wg_elapsed=$((_wg_elapsed + 5))
    done
    return 1
  elif [ "$_wg_type" = "macOS" ]; then
    # SSH check (macOS guests in Tart expose SSH on the manifest forwarded
    # host port for guest 22)
    while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$_wg_ssh_port" \
        "${vm_guest_username:?}@localhost" true 2>/dev/null && return 0
      sleep 5
      _wg_elapsed=$((_wg_elapsed + 5))
    done
    return 1
  fi
  return 1
}

# vm_write_start_script NAME DISPLAY TYPE HOST_KIND
# Args:
#   $1 — VM machine name (manifest .id)
#   $2 — VM display name (manifest .name)
#   $3 — VM type (macOS/NixOS/Windows/...)
#   $4 — host runtime kind (darwin-utm|darwin-tart|nixos-libvirt)
# Writes a host-side helper script to start the VM runtime from ~/virtual machines.
vm_write_start_script() {
  _wss_name="$1"
  _wss_display="$2"
  _wss_type="$3"
  _wss_host_kind="$4"
  mkdir -p "$VM_DIR/scripts"
  _wss_path_sh="$VM_DIR/scripts/start-${_wss_name}.sh"
  _wss_path_ps1="$VM_DIR/scripts/start-${_wss_name}.ps1"

  if [ "$dry_run" = true ]; then
    dry_run "write start helper scripts: $_wss_path_sh, $_wss_path_ps1"
    return 0
  fi

  # Render .sh from template.
  if [ -f "$TEMPLATES_DIR/start-posix.sh" ]; then
    sed -e "s|__VM_NAME__|$_wss_name|g" \
        -e "s|__VM_DISPLAY__|$_wss_display|g" \
        -e "s|__VM_TYPE__|$_wss_type|g" \
        -e "s|__HOST_KIND__|$_wss_host_kind|g" \
        -e "s|__VM_DIR__|$VM_DIR|g" \
        "$TEMPLATES_DIR/start-posix.sh" >"$_wss_path_sh"
  else
    warn "start-posix.sh template not found at $TEMPLATES_DIR/start-posix.sh"
    printf '#!/bin/sh\nset -eu\necho "VM start script for %s"\n' "$_wss_name" >"$_wss_path_sh"
  fi
  chmod 755 "$_wss_path_sh"

  # Render .ps1 from the shared host-kind dispatcher template
  # (embedded-content policy: single shared file per platform).
  case "$_wss_host_kind" in
    darwin-tart|darwin-utm|nixos-libvirt)
      if [ -f "$TEMPLATES_DIR/start-host.ps1" ]; then
        sed -e "s|__HOST_KIND__|$_wss_host_kind|g" \
            -e "s|__VM_NAME__|$_wss_name|g" \
            -e "s|__VM_DISPLAY__|$_wss_display|g" \
            -e "s|__VM_DIR__|$VM_DIR|g" \
            "$TEMPLATES_DIR/start-host.ps1" >"$_wss_path_ps1"
      else
        warn "start-host.ps1 template not found at $TEMPLATES_DIR/start-host.ps1"
        printf '# start script for %s\n' "$_wss_name" >"$_wss_path_ps1"
      fi
      ;;
    windows-qemu)
      if [ "$_wss_type" = "Android" ]; then
        # WHY: the Android QEMU start script is shared cross-platform content
        # (embedded-content policy); render the canonical file instead of an
        # embedded copy (which had drifted and wrote literal backticks).
        _wss_android_start="$REPO_ROOT/src/scripts/vms/start-android-vm.ps1"
        if [ ! -f "$_wss_android_start" ]; then
          error "shared Android VM start script not found: $_wss_android_start"
          return 1
        fi
        # Manifest-driven tokens: CPU count, RAM bytes, image filenames, and the
        # ADB/console host ports from VMs.json portForwards (single-source
        # start script).  Image names come from the manifest Android group.
        _wss_cpus="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .cpus' "$MANIFEST")"
        _wss_ram_bytes="$(parse_size "$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .ram' "$MANIFEST")")"
        _wss_system_image="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .Android.systemImage' "$MANIFEST")"
        _wss_userdata_image="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .Android.userdataImage' "$MANIFEST")"
        _wss_gsi_image="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .Android.gsiImage' "$MANIFEST")"
        _wss_adb_port="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .portForwards[] | select(.guestPort == 5555) | .hostPort' "$MANIFEST")"
        _wss_console_port="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .portForwards[] | select(.guestPort == 5554) | .hostPort' "$MANIFEST")"
        sed -e "s|__ANDROID_CPU_COUNT__|$_wss_cpus|g" \
            -e "s|__ANDROID_RAM_BYTES__|${_wss_ram_bytes}B|g" \
            -e "s|__ANDROID_SYSTEM_IMAGE__|$_wss_system_image|g" \
            -e "s|__ANDROID_USERDATA_IMAGE__|$_wss_userdata_image|g" \
            -e "s|__ANDROID_GSI_IMAGE__|$_wss_gsi_image|g" \
            -e "s|__ADB_PORT__|$_wss_adb_port|g" \
            -e "s|__ADB_CONSOLE_PORT__|$_wss_console_port|g" \
            "$_wss_android_start" >"$_wss_path_ps1"
      else
        # Windows VM start scripts mirror Invoke-VMSetup.ps1 rendering (Git
        # Bash host): the cross-host templates stay single-source and all
        # tokens come from the manifest (portForwards, cpus, ram, id).
        _wss_hostfwds="$(jq -r --arg n "$_wss_name" '[.VMs[] | select(.id == $n) | .portForwards[] | "hostfwd=tcp::\(.hostPort)-:\(.guestPort)"] | join(",")' "$MANIFEST")"
        _wss_cpus="$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .cpus' "$MANIFEST")"
        _wss_ram_bytes="$(parse_size "$(jq -r --arg n "$_wss_name" '.VMs[] | select(.id == $n) | .ram' "$MANIFEST")")"
        _wss_disk_path="$VM_DIR/${_wss_name}.qcow2"
        _wss_qemu_arch="x86_64"
        if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
          _wss_qemu_arch="aarch64"
        fi
        _wss_qemu_system="$HOME/scoop/apps/qemu/current/qemu-system-${_wss_qemu_arch}.exe"
        if [ "$_wss_qemu_arch" = "x86_64" ]; then
          _wss_machine="q35"
        else
          _wss_machine="virt"
        fi
        if [ -f "$TEMPLATES_DIR/start-windows.ps1" ]; then
          sed -e "s|__QEMU_SYSTEM__|$_wss_qemu_system|g" \
              -e "s|__VM_NAME__|$_wss_name|g" \
              -e "s|__VM_DISPLAY__|$_wss_display|g" \
              -e "s|__MACHINE__|$_wss_machine|g" \
              -e "s|__CPU__|host|g" \
              -e "s|__CPUS__|$_wss_cpus|g" \
              -e "s|__RAM_BYTES__|$_wss_ram_bytes|g" \
              -e "s|__DISK_PATH__|$_wss_disk_path|g" \
              -e "s|__HOSTFWDS__|$_wss_hostfwds|g" \
              -e "s|__VGA__|std|g" \
              -e "s|__DISPLAY_BACKEND__|sdl|g" \
              -e "s|__VIRTIOFS_ARGS__||g" \
              "$TEMPLATES_DIR/start-windows.ps1" >"$_wss_path_ps1"
        else
          warn "start-windows.ps1 template not found at $TEMPLATES_DIR/start-windows.ps1"
          printf '# start script for %s\n' "$_wss_name" >"$_wss_path_ps1"
        fi
        if [ -f "$TEMPLATES_DIR/start-windows-host.sh" ]; then
          sed -e "s|__QEMU_SYSTEM__|$_wss_qemu_system|g" \
              -e "s|__VM_NAME__|$_wss_name|g" \
              -e "s|__VM_DISPLAY__|$_wss_display|g" \
              -e "s|__MACHINE__|$_wss_machine|g" \
              -e "s|__CPU__|host|g" \
              -e "s|__CPUS__|$_wss_cpus|g" \
              -e "s|__RAM_BYTES__|$_wss_ram_bytes|g" \
              -e "s|__DISK_PATH__|$_wss_disk_path|g" \
              -e "s|__HOSTFWDS__|$_wss_hostfwds|g" \
              -e "s|__VGA__|std|g" \
              -e "s|__DISPLAY_BACKEND__|sdl|g" \
              "$TEMPLATES_DIR/start-windows-host.sh" >"$_wss_path_sh"
          chmod 755 "$_wss_path_sh"
        else
          warn "start-windows-host.sh template not found at $TEMPLATES_DIR/start-windows-host.sh"
        fi
      fi
      ;;
    *)
      error "unknown start-script host kind: $_wss_host_kind"
      return 1
      ;;
  esac
  chmod 755 "$_wss_path_ps1"

  say "wrote start helper scripts: $_wss_path_sh, $_wss_path_ps1"
}

# vm_write_stop_script NAME DISPLAY TYPE HOST_KIND
# Args:
#   $1 — VM machine name (manifest .id)
#   $2 — VM display name (manifest .name)
#   $3 — VM type (macOS/NixOS/Windows/...)
#   $4 — host runtime kind (darwin-utm|darwin-tart|nixos-libvirt|windows-qemu)
# Writes a host-side helper script to stop the VM runtime from ~/virtual machines.
vm_write_stop_script() {
  _wst_name="$1"
  _wst_display="$2"
  _wst_host_kind="$4"
  mkdir -p "$VM_DIR/scripts"
  _wst_path_sh="$VM_DIR/scripts/stop-${_wst_name}.sh"
  _wst_path_ps1="$VM_DIR/scripts/stop-${_wst_name}.ps1"

  if [ "$dry_run" = true ]; then
    dry_run "write stop helper scripts: $_wst_path_sh, $_wst_path_ps1"
    return 0
  fi

  # Render .sh from the shared host-kind dispatcher template
  # (embedded-content policy: single shared file per platform).
  case "$_wst_host_kind" in
    darwin-tart|darwin-utm|nixos-libvirt)
      if [ -f "$TEMPLATES_DIR/stop-posix.sh" ]; then
        sed -e "s|__HOST_KIND__|$_wst_host_kind|g" \
            -e "s|__VM_NAME__|$_wst_name|g" \
            -e "s|__VM_DISPLAY__|$_wst_display|g" \
            "$TEMPLATES_DIR/stop-posix.sh" >"$_wst_path_sh"
      else
        warn "stop-posix.sh template not found at $TEMPLATES_DIR/stop-posix.sh"
        printf '#!/bin/sh\nset -eu\necho "stop script for %s"\n' "$_wst_name" >"$_wst_path_sh"
      fi
      ;;
    *)
      error "unknown stop-script host kind: $_wst_host_kind"
      return 1
      ;;
  esac
  chmod 755 "$_wst_path_sh"

  # Render .ps1 from the shared host-kind dispatcher template
  # (embedded-content policy: single shared file per platform).
  case "$_wst_host_kind" in
    darwin-tart|darwin-utm|nixos-libvirt|windows-qemu)
      if [ -f "$TEMPLATES_DIR/stop-host.ps1" ]; then
        sed -e "s|__HOST_KIND__|$_wst_host_kind|g" \
            -e "s|__VM_NAME__|$_wst_name|g" \
            "$TEMPLATES_DIR/stop-host.ps1" >"$_wst_path_ps1"
      else
        warn "stop-host.ps1 template not found at $TEMPLATES_DIR/stop-host.ps1"
        printf '# stop script for %s\n' "$_wst_name" >"$_wst_path_ps1"
      fi
      ;;
    *)
      error "unknown stop-script host kind: $_wst_host_kind"
      return 1
      ;;
  esac

  say "wrote stop helper scripts: $_wst_path_sh, $_wst_path_ps1"
}

# VM iteration helper

# vm_for_each CALLBACK [ARGS...]
#   Iterates VMs in MANIFEST, skipping disabled or host-mismatched entries.
#   For each enabled VM, calls CALLBACK with positional args:
#     vm_name vm_type vm_hosts vm_index [ARGS...]
vm_for_each() {
  local _callback="$1"
  shift
  local _count _i _vm_name _vm_type _vm_enabled _vm_hosts
  _count="$(jq '.VMs | length' "$MANIFEST")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _vm_name="$(jq -r ".VMs[$_i].id" "$MANIFEST")"
    _vm_type="$(jq -r ".VMs[$_i].type" "$MANIFEST")"
    _vm_enabled="$(jq -r ".VMs[$_i].enabled" "$MANIFEST")"

    case "$_vm_enabled" in
      true|false) ;;
      *)
        warn "VM '$_vm_name' has invalid enabled value '$_vm_enabled'; expected boolean true/false in manifest"
        _i=$((_i + 1))
        continue
        ;;
    esac

    if [ "$_vm_enabled" != "true" ]; then
      say "VM '$_vm_name' is disabled in manifest; skipping"
      _i=$((_i + 1))
      continue
    fi

    _vm_hosts="$(jq -c ".VMs[$_i].hosts" "$MANIFEST")"
    if ! should_include_host "$_vm_hosts"; then
      say "VM '$_vm_name' is not available on host '$NUCLEUS_HOST' (hosts: $_vm_hosts); skipping"
      _i=$((_i + 1))
      continue
    fi

    "$_callback" "$_vm_name" "$_vm_type" "$_vm_hosts" "$_i" "$@"
    _i=$((_i + 1))
  done
}

# vm_get_expected_vm_names
#   Prints a newline-separated list of VM names from the manifest that are
#   enabled and match the current host.  Reuses the same filter logic as
#   vm_for_each but without the callback dispatch.
vm_get_expected_vm_names() {
  jq -r --arg host "$NUCLEUS_HOST" '
    .VMs[] |
    select(.enabled == true) |
    select(.hosts | contains([$host])) |
    .id
  ' "$MANIFEST"
}

# vm_get_manifest_vm_names
#   Prints a newline-separated list of ALL VM names present in the manifest,
#   regardless of enabled state or host match.  Used by default GC so only
#   entries absent from VMs.json entirely are cleared; disabled entries are
#   preserved unless --gc-disabled is passed.
vm_get_manifest_vm_names() {
  jq -r '.VMs[] | .id' "$MANIFEST"
}

# vm_descriptor_path NAME
#   Prints the path of the self-describing descriptor for a VM:
#   <VM_DIR>/<NAME>.vm.json.
vm_descriptor_path() {
  printf '%s/%s.vm.json\n' "$VM_DIR" "$1"
}

# vm_mk_uuid NAME
#   Prints the deterministic 8-4-4-4-12 UUID for a VM, derived from the
#   SHA-256 of the guest id. Mirrors mkUuid in src/hosts/MacBook/vms.nix
#   (uuidFromDigest of hashString "sha256" id).
vm_mk_uuid() {
  local _vmu_id="$1" _vmu_h
  _vmu_h="$(printf '%s' "$_vmu_id" | vm_sha256_input)" || return 1
  printf '%s-%s-%s-%s-%s' \
    "${_vmu_h:0:8}" "${_vmu_h:8:4}" "${_vmu_h:12:4}" "${_vmu_h:16:4}" "${_vmu_h:20:12}"
}

# vm_mk_mac_address NAME PREFIX
#   Prints the deterministic MAC address (PREFIX + 5 hex octets) for a VM,
#   derived from the SHA-256 of "mac:<NAME>". Mirrors mkMacAddress in
#   src/hosts/MacBook/vms.nix.
vm_mk_mac_address() {
  local _vmm_id="$1" _vmm_prefix="$2" _vmm_h
  _vmm_h="$(printf 'mac:%s' "$_vmm_id" | vm_sha256_input)" || return 1
  printf '%s:%s:%s:%s:%s:%s' \
    "$_vmm_prefix" "${_vmm_h:0:2}" "${_vmm_h:2:2}" "${_vmm_h:4:2}" "${_vmm_h:6:2}" "${_vmm_h:8:2}"
}

# vm_derive_arch TYPE
#   Prints the guest architecture for a VM type. Mirrors vmArch in
#   src/hosts/MacBook/vms.nix: Android is always aarch64, Windows always
#   x86_64, other types follow the host architecture.
vm_derive_arch() {
  local _vda_type="$1" _vda_host
  case "$_vda_type" in
    Android) printf 'aarch64\n'; return 0 ;;
    Windows) printf 'x86_64\n'; return 0 ;;
  esac
  _vda_host="$(uname -m)"
  case "$_vda_host" in
    arm64|aarch64) printf 'aarch64\n' ;;
    *) printf 'x86_64\n' ;;
  esac
}

# vm_derive_machine ARCH
#   Prints the QEMU machine type for an architecture. Mirrors vmMachine in
#   src/hosts/MacBook/vms.nix: x86_64 → q35, everything else → virt.
vm_derive_machine() {
  if [ "$1" = "x86_64" ]; then
    printf 'q35\n'
  else
    printf 'virt\n'
  fi
}

# vm_derive_uefi TYPE ARCH
#   Prints whether the guest boots via UEFI. Mirrors qemuUefiBoot in
#   src/hosts/MacBook/vms.nix: every non-Windows aarch64 guest uses UEFI.
vm_derive_uefi() {
  if [ "$1" != "Windows" ] && [ "$2" = "aarch64" ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# vm_write_descriptor ID TYPE INDEX
#   Writes the self-describing descriptor <ID>.vm.json for the manifest VM at
#   INDEX: manifest fields (id/name/type/enabled/cpus/ram/diskSize/
#   portForwards + the type group when present) plus derived hardware identity
#   (uuid/mac/arch/machine/uefi), the disks array, and createdBy. Written for
#   EVERY manifest guest (enabled or disabled) so scripts/ and unpack can
#   serve disabled VMs without a live manifest. Atomic (temp + mv); honors
#   dry_run.
vm_write_descriptor() {
  local _vwd_id="$1" _vwd_type="$2" _vwd_index="$3"
  local _vwd_path _vwd_uuid _vwd_mac_prefix _vwd_mac _vwd_arch _vwd_machine _vwd_uefi
  local _vwd_tmp

  _vwd_path="$(vm_descriptor_path "$_vwd_id")"
  if [ "$dry_run" = true ]; then
    dry_run "write VM descriptor: $_vwd_path"
    return 0
  fi

  _vwd_uuid="$(vm_mk_uuid "$_vwd_id")" || return 1
  _vwd_mac_prefix="$(jq -r --argjson i "$_vwd_index" '.VMs[$i].macAddressPrefix // ""' "$MANIFEST")"
  if [ -z "$_vwd_mac_prefix" ]; then
    error "VM '$_vwd_id' lacks macAddressPrefix in manifest; every managed VM must have a deterministic MAC"
    return 1
  fi
  _vwd_mac="$(vm_mk_mac_address "$_vwd_id" "$_vwd_mac_prefix")"
  _vwd_arch="$(vm_derive_arch "$_vwd_type")"
  _vwd_machine="$(vm_derive_machine "$_vwd_arch")"
  _vwd_uefi="$(vm_derive_uefi "$_vwd_type" "$_vwd_arch")"

  _vwd_tmp="$_vwd_path.tmp.$$"
  jq -c \
    --argjson i "$_vwd_index" \
    --arg uuid "$_vwd_uuid" \
    --arg mac "$_vwd_mac" \
    --arg arch "$_vwd_arch" \
    --arg machine "$_vwd_machine" \
    --arg uefi "$_vwd_uefi" \
    --arg schema "$REPO_ROOT/src/modules/vm-descriptor.schema.json" \
    --arg createdBy "nucleus-vm" \
    '
    .VMs[$i] as $vm |
    {
      "$schema": $schema,
      id: $vm.id,
      name: $vm.name,
      type: $vm.type,
      enabled: $vm.enabled,
      cpus: $vm.cpus,
      ram: $vm.ram,
      diskSize: $vm.diskSize,
      portForwards: ($vm.portForwards // []),
      uuid: $uuid,
      mac: $mac,
      arch: $arch,
      machine: $machine,
      uefi: ($uefi == "true"),
      disks: (
        if $vm.type == "Android" then
          [
            {role: "system", path: ("images/" + $vm.type + "-system.qcow2")},
            {role: "gsi", path: ("images/" + $vm.type + "-gsi.img")},
            {role: "userdata", path: ("data/" + $vm.id + ".qcow2")}
          ]
        else
          [
            {role: "base", path: ("images/" + $vm.type + ".base.qcow2")},
            {role: "runtime", path: ("data/" + $vm.id + ".qcow2")}
          ]
        end
      ),
      createdBy: $createdBy
    }
    + (if $vm.Android then {Android: $vm.Android} else {} end)
    + (if $vm.macOS then {macOS: $vm.macOS} else {} end)
    + (if $vm.Windows then {Windows: $vm.Windows} else {} end)
    ' "$MANIFEST" >"$_vwd_tmp" || return 1
  mv "$_vwd_tmp" "$_vwd_path"
  say "wrote VM descriptor: $_vwd_path"
}

# vm_write_descriptors
#   Writes a descriptor for EVERY guest in the manifest (enabled or disabled,
#   host-matched or not), unlike vm_for_each.
vm_write_descriptors() {
  local _count _i _id _type
  _count="$(jq '.VMs | length' "$MANIFEST")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _id="$(jq -r ".VMs[$_i].id" "$MANIFEST")"
    _type="$(jq -r ".VMs[$_i].type" "$MANIFEST")"
    vm_write_descriptor "$_id" "$_type" "$_i"
    _i=$((_i + 1))
  done
}

# UTM re-registration helper

UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

# re_register_utm_bundle NAME BUNDLE
#   Force UTM to reload bundle config by temporarily preserving the bundle,
#   deleting the registered VM entry, then reopening the preserved bundle.
#   WHY: UTM can keep stale runtime config for already-registered VMs even
#   after config.plist is refreshed in-place.
re_register_utm_bundle() {
  local _rr_name="$1" _rr_bundle="$2" _rr_backup
  _rr_backup="${_rr_bundle}.reimport"

  rm -rf "$_rr_backup"
  if ! cp -R "$_rr_bundle" "$_rr_backup"; then
    warn "failed to stage re-registration backup for $_rr_name; keeping current registration"
    return 1
  fi

  if ! "$UTMCTL" delete "$_rr_name"; then
    warn "failed to delete stale UTM registration for $_rr_name; keeping current registration"
    rm -rf "$_rr_backup"
    return 1
  fi

  if [ -d "$_rr_bundle" ]; then
    rm -rf "$_rr_bundle"
  fi

  if ! mv "$_rr_backup" "$_rr_bundle"; then
    warn "failed to restore bundle after re-registration delete for $_rr_name"
    return 1
  fi

  say "re-opening UTM bundle to refresh registration: $_rr_bundle"
  if ! open "$_rr_bundle"; then
    warn "opening $_rr_bundle failed after re-registration; open it manually in UTM"
    return 1
  fi

  if ! wait_for_utm_registration "$_rr_name"; then
    warn "UTM did not re-register VM '$_rr_name' within timeout after stale-config repair"
    return 1
  fi

  return 0
}

# Credential marker helper

# resize_and_mark_image IMAGE_PATH MARKER_PATH [DISK_BYTES]
#   Writes the current guest credential fingerprint to MARKER_PATH for drift
#   detection.  When DISK_BYTES is specified, also resizes IMAGE_PATH via
#   qemu-img before marking (qemu-img accepts bare byte counts).
resize_and_mark_image() {
  local _rmi_file="$1" _rmi_marker="$2" _rmi_disk_bytes="${3:-}"

  if [ -n "$_rmi_disk_bytes" ]; then
    if command -v qemu-img >/dev/null 2>&1; then
      if ! qemu-img resize "$_rmi_file" "$_rmi_disk_bytes" >/dev/null; then
        error "failed to resize $_rmi_file to $_rmi_disk_bytes bytes"
        return 1
      fi
    else
      error "qemu-img not found; cannot resize $_rmi_file to $_rmi_disk_bytes bytes"
      return 1
    fi
  fi
  printf '%s\n' "$vm_guest_credentials_fingerprint" >"$_rmi_marker"
}

# android (qemu/lineageos) image build

vm_build_android() {
  _bai_vm_name="$1"
  _bai_vm_index="$2"
  _bai_accept_gsi_license="$3"
  _bai_upgrade_android="$4"
  _bai_reset_userdata="$5"
  # The Android userdata disk size comes from the manifest (diskSize),
  # parsed to exact bytes; a hardcoded size here would silently ignore
  # VMs.json.
  _bai_disk_bytes="$(parse_size "$(jq -r ".VMs[$_bai_vm_index].diskSize" "$MANIFEST")")"
  _bai_gsi_url="$(jq -r ".VMs[$_bai_vm_index].Android.gsiUrl" "$MANIFEST")"
  # Image filenames come from the manifest Android group (systemImage /
  # userdataImage / gsiImage) so VMs.json is the single source of truth.
  _bai_system_img="$IMAGES_DIR/$(jq -r ".VMs[$_bai_vm_index].Android.systemImage" "$MANIFEST")"
  _bai_userdata_img="$IMAGES_DIR/$(jq -r ".VMs[$_bai_vm_index].Android.userdataImage" "$MANIFEST")"
  _bai_gsi_img="$IMAGES_DIR/$(jq -r ".VMs[$_bai_vm_index].Android.gsiImage" "$MANIFEST")"

  # shareDevDir is unsupported on Android (no host filesystem sharing via QEMU).
  _bai_share_dev_dir="$(jq -r ".VMs[$_bai_vm_index].shareDevDir // false" "$MANIFEST")"
  if [ "$_bai_share_dev_dir" = "true" ]; then
    error "shareDevDir is not supported for Android VM '$_bai_vm_name'; Android does not support host filesystem sharing via QEMU"
    exit 1
  fi

  # Step 1: Download and extract LineageOS base system image
  if [ ! -f "$_bai_system_img" ] || [ "$_bai_upgrade_android" = "true" ]; then
    if [ "$_bai_upgrade_android" = "true" ] && [ -f "$_bai_system_img" ]; then
      say "upgrading Android system image for '$_bai_vm_name' (re-downloading)..."
      rm -f "$_bai_system_img"
    else
      say "downloading LineageOS base image for '$_bai_vm_name'..."
    fi
    run_with_backoff "download LineageOS release metadata" \
      curl -fsSL -o "$IMAGES_DIR/android-lineage-release.json" \
      "https://api.github.com/repos/jqssun/android-lineage-qemu/releases/latest" \
      || { error "failed to fetch latest LineageOS release info"; return 1; }
    _bai_dl_url="$(jq -r '.assets[] | select(.name | test("UTM-VM-lineage-.*-virtio_arm64only\\.zip")) | .browser_download_url' "$IMAGES_DIR/android-lineage-release.json" | head -1)"
    if [ -z "$_bai_dl_url" ] || [ "$_bai_dl_url" = "null" ]; then
      error "no LineageOS UTM zip found in latest release assets"
      return 1
    fi
    run_with_backoff "download LineageOS zip" \
      curl -fL -o "$IMAGES_DIR/android-lineage.zip" "$_bai_dl_url" \
      || { error "failed to download LineageOS zip"; return 1; }
    say "extracting LineageOS system image..."
    _bai_extract_dir="$IMAGES_DIR/android-lineage-extract"
    rm -rf "$_bai_extract_dir"
    mkdir -p "$_bai_extract_dir"
    run_cmd unzip -q "$IMAGES_DIR/android-lineage.zip" -d "$_bai_extract_dir"
    # UTM bundle layouts differ across versions (vda.qcow2 in UTM 1-3,
    # disk-main.qcow2 in UTM 4); pick the largest qcow2 as the system image.
    # tr strips the whitespace wc -c pads its output with (macOS pads; Linux
    # does not), which would otherwise leak into the path after cut.
    _bai_qcow2="$(find "$_bai_extract_dir" -type f -name '*.qcow2' -print | while IFS= read -r _f; do printf '%s %s\n' "$(wc -c < "$_f" | tr -d '[:space:]')" "$_f"; done | sort -rn | head -1 | cut -d' ' -f2-)"
    if [ -z "$_bai_qcow2" ]; then
      error "no qcow2 system image found inside extracted LineageOS bundle"
      return 1
    fi
    run_cmd cp "$_bai_qcow2" "$_bai_system_img"
    rm -rf "$_bai_extract_dir" "$IMAGES_DIR/android-lineage.zip" "$IMAGES_DIR/android-lineage-release.json"
    validate_qcow2_image "$_bai_system_img" "Android system image for $_bai_vm_name" "$(parse_size "$(jq -r ".VMs[$_bai_vm_index].minImageSize" "$MANIFEST")")" || return 1
    say "system image ready: $_bai_system_img"
  else
    say "system image already exists: $_bai_system_img"
  fi

  # Step 2: Create userdata disk (skip if exists, unless reset requested)
  if [ ! -f "$_bai_userdata_img" ] || [ "$_bai_reset_userdata" = "true" ]; then
    if [ "$_bai_reset_userdata" = "true" ] && [ -f "$_bai_userdata_img" ]; then
      say "resetting Android userdata disk..."
      rm -f "$_bai_userdata_img"
    fi
    say "creating userdata disk (${_bai_disk_bytes} bytes)..."
    run_cmd qemu-img create -f qcow2 "$_bai_userdata_img" "$_bai_disk_bytes"
    validate_qcow2_image "$_bai_userdata_img" "Android userdata disk for $_bai_vm_name" "$(parse_size "$(jq -r ".VMs[$_bai_vm_index].minImageSize" "$MANIFEST")")" || return 1
    say "userdata disk ready: $_bai_userdata_img"
  else
    say "userdata disk already exists: $_bai_userdata_img"
  fi

  # Step 3: GSI system image (optional, when the Android group's gsiUrl is set)
  if [ -n "$_bai_gsi_url" ] && [ "$_bai_gsi_url" != "null" ]; then
    if [ "$_bai_accept_gsi_license" != "true" ]; then
      error "GSI license not accepted for '$_bai_vm_name'; see https://developer.android.com/license"
      exit 1
    fi
    say "GSI license: https://developer.android.com/license"
    if [ ! -f "$_bai_gsi_img" ]; then
      say "downloading GSI system image..."
      _bai_gsi_zip="$IMAGES_DIR/android-gsi.zip"
      run_with_backoff "download GSI zip" \
        curl -fL -o "$_bai_gsi_zip" "$_bai_gsi_url" \
        || { error "failed to download GSI zip from $_bai_gsi_url"; return 1; }
      say "extracting GSI system.img..."
      run_cmd unzip -q -o "$_bai_gsi_zip" system.img -d "$(dirname "$_bai_gsi_img")"
      run_cmd mv "$(dirname "$_bai_gsi_img")/system.img" "$_bai_gsi_img"
      rm -f "$_bai_gsi_zip"
      if [ ! -f "$_bai_gsi_img" ]; then
        error "GSI system.img not found after extraction"
        return 1
      fi
      say "GSI system image ready: $_bai_gsi_img"
    else
      say "GSI system image already exists: $_bai_gsi_img"
    fi
  else
    say "no GSI URL set; using built-in LineageOS GSI"
  fi

  say "Android image build complete for '$_bai_vm_name'"
}

# Image build callback for vm_for_each

vm_build_one_image() {
  local _vm_name="$1" _vm_type="$2" _vm_hosts="$3" _vm_index="$4"
  local _vm_disk_bytes _vm_ram_bytes
  _vm_disk_bytes="$(parse_size "$(jq -r ".VMs[$_vm_index].diskSize" "$MANIFEST")")"

  # Per-VM guest hostname: guest builds (nixos-generators, packer) read it via
  # NUCLEUS_VM_GUEST_HOSTNAME so each VM's declared hostname reaches the guest.
  local _vm_guest_hostname
  _vm_guest_hostname="$(jq -r --arg n "$_vm_name" '.VMs[] | select(.id == $n) | .hostname // empty' "$MANIFEST")"
  export NUCLEUS_VM_GUEST_HOSTNAME="$_vm_guest_hostname"

  case "$_vm_type" in
    NixOS)
      # check-suppress:suppression_doc: best-effort -- a prerequisite-missing or build failure for one
      # VM type must not abort builds for the remaining VMs; the build
      # function prints a specific error before returning non-zero.
      vm_build_nixos "$_vm_name" "$_vm_disk_bytes" \
        || say "NixOS image build skipped for '$_vm_name' (prerequisite missing or build failed; see above)"
      ;;
    Windows)
      _vm_edition="$(jq -r ".VMs[$_vm_index].Windows.edition" "$MANIFEST")"
      # check-suppress:suppression_doc: best-effort -- see NixOS branch above.
      vm_build_windows "$_vm_name" "$_vm_disk_bytes" "$_vm_edition" \
        || say "Windows image build skipped for '$_vm_name' (prerequisite missing or build failed; see above)"
      ;;
    macOS)
      _vm_macos_ver="$(jq -r ".VMs[$_vm_index].macOS.version" "$MANIFEST")"
      _vm_ram_bytes="$(parse_size "$(jq -r ".VMs[$_vm_index].ram" "$MANIFEST")")"
      _vm_cpus="$(jq -r ".VMs[$_vm_index].cpus" "$MANIFEST")"
      # check-suppress:suppression_doc: best-effort -- see NixOS branch above.
      vm_build_macos "$_vm_name" "$_vm_disk_bytes" "$_vm_ram_bytes" "$_vm_cpus" "$_vm_macos_ver" \
        || say "macOS image build skipped for '$_vm_name' (prerequisite missing or build failed; see above)"
      ;;
    Android)
      # check-suppress:suppression_doc: best-effort -- see NixOS branch above.
      vm_build_android "$_vm_name" "$_vm_index" \
        "$accept_gsi_license" "$upgrade_android" "$reset_userdata" \
        || say "Android image build skipped for '$_vm_name' (prerequisite missing or build failed; see above)"
      ;;
    *)
      say "skipping build for '$_vm_name' (unsupported type: $_vm_type)"
      ;;
  esac
}

# Tart VM setup callback for vm_for_each

vm_setup_tart() {
  local vm_name="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"

  if [ "$vm_type" != "macOS" ]; then
    return
  fi

  # Verify the tart VM was created in phase 1.
  if ! tart list 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$vm_name"; then
    warn "tart VM '$vm_name' not found; Packer build may have failed or was skipped"
    return
  fi

  if [ "$dry_run" = false ]; then
    say "tart VM ready: $vm_name (start with: tart run $vm_name)"
    vm_write_start_script "$vm_name" "$vm_name" "$vm_type" 'darwin-tart'
    vm_write_stop_script "$vm_name" "$vm_name" "$vm_type" 'darwin-tart'
  else
    dry_run "verify tart VM registration: $vm_name"
  fi
}

# UTM VM setup callback for vm_for_each

vm_setup_utm() {
  local vm_name="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display bundle data_dir disk_file
  local disk_credential_marker disk_config_marker config_plist bundle_exists legacy_display_config
  local template_drift_config _plist_template _prebuilt _prebuilt_valid
  local _android_system _android_userdata _android_gsi _userdata_file _gsi_file
  local _guest_config_fingerprint

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")

  # macOS guests are provisioned via tart (vm_setup_tart_vms), not UTM.
  if [ "$vm_type" = "macOS" ]; then
    say "macOS guest '$vm_name' stays on Tart runtime; skipping UTM bundle provisioning for this VM"
    return
  fi

  bundle="$VM_DIR/${vm_name}.utm"
  data_dir="$bundle/Data"
  disk_file="$data_dir/disk-main.qcow2"
  disk_credential_marker="$(vm_guest_credentials_marker_path "$vm_name" "$disk_file")"
  disk_config_marker="$(vm_guest_config_marker_path "$vm_name" "$disk_file")"
  # WHY: only NixOS guests have a Nix-managed guest config to fingerprint;
  # Windows/macOS are built by Packer with separate templates.
  _guest_config_fingerprint=''
  if [ "$vm_type" = "NixOS" ]; then
    _guest_config_fingerprint="$(vm_guest_config_fingerprint)"
  fi
  config_plist="$bundle/config.plist"
  bundle_exists=false
  legacy_display_config=false
  template_drift_config=false

  say "configuring UTM VM '$vm_display'..."

  if [ -d "$bundle" ]; then
    bundle_exists=true
    say "UTM bundle already exists: $bundle; refreshing config.plist"
    if [ -f "$config_plist" ] && grep -qE '<string>(vga|std|virtio-ramfb|virtio-ramfb-gl)</string>' "$config_plist"; then
      legacy_display_config=true
      say "detected legacy display config in existing bundle; VM will be re-registered to refresh runtime state: $vm_name"
    fi
  fi

  # Use the Nix-generated UTM config.plist written to ~/.local/share/nucleus/
  # at Home Manager activation time (run nucleus-apply first).
  _plist_template="${HOME}/.local/share/nucleus/vms/${vm_name}-config.plist"
  if [ ! -f "$_plist_template" ]; then
    warn "UTM config template not found at $_plist_template; apply the macOS config first"
    return
  fi
  # Detect stale templates from older schema/value generations and fail fast
  # with a concrete action instead of copying a known-invalid plist.
  if grep -qE 'virtio-ramfb-gl|<key>DirectorySharing</key>|<key>ReadOnlySharing</key>|<key>SharedDirectories</key>' "$_plist_template"; then
    warn "stale UTM template detected at $_plist_template; run home-manager switch (or nucleus apply) before vm-setup"
    return
  fi
  _required_utm_keys='
<key>IconCustom</key>
<key>Sound</key>
<key>ClipboardSharing</key>
<key>DirectoryShareReadOnly</key>
<key>DownscalingFilter</key>
<key>UpscalingFilter</key>
<key>NativeResolution</key>
<key>MacAddress</key>
<key>IsolateFromHost</key>
<key>PortForward</key>
<key>AdditionalArguments</key>
<key>BalloonDevice</key>
<key>DebugLog</key>
<key>PS2Controller</key>
<key>RNGDevice</key>
<key>RTCLocalTime</key>
<key>TPMDevice</key>
<key>MaximumUsbShare</key>
<key>UsbBusSupport</key>
<key>UsbSharing</key>
<key>CPUFlagsAdd</key>
<key>CPUFlagsRemove</key>
<key>ForceMulticore</key>
<key>JITCacheSize</key>'
  _missing_utm_keys=''
  for _required_utm_key in $_required_utm_keys; do
    if ! grep -Fq "$_required_utm_key" "$_plist_template"; then
      _missing_utm_keys="$_missing_utm_keys ${_required_utm_key#<key>}"
    fi
  done
  if [ -n "$_missing_utm_keys" ]; then
    warn "stale or incomplete UTM template detected at $_plist_template (missing key(s):$_missing_utm_keys); run home-manager switch (or nucleus apply) before vm-setup"
    return
  fi
  # Detect config drift in already-registered bundles. UTM can keep runtime
  # state from the registered entry, so we re-register when the on-disk
  # bundle config no longer matches the managed template.
  if [ "$bundle_exists" = true ] && [ -f "$config_plist" ] && ! cmp -s "$_plist_template" "$config_plist"; then
    template_drift_config=true
    say "detected config drift in existing bundle; VM will be re-registered to refresh runtime state: $vm_name"
  fi
  # Android uses the shared android-* images (system + userdata, optional GSI)
  # rather than a single <Name>.qcow2 pre-built image; other guests keep the
  # ${vm_name}.qcow2 convention.  Image filenames come from the manifest
  # Android group (systemImage / userdataImage / gsiImage).
  if [ "$vm_type" = "Android" ]; then
    _android_system="$IMAGES_DIR/$(jq -r ".VMs[$vm_index].Android.systemImage" "$MANIFEST")"
    _android_userdata="$IMAGES_DIR/$(jq -r ".VMs[$vm_index].Android.userdataImage" "$MANIFEST")"
    _android_gsi="$IMAGES_DIR/$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")"
  fi

  # Require a pre-built image only when the bundle does not already have a
  # disk. Existing bundles can refresh config.plist in-place.
  if [ "$vm_type" = "Android" ]; then
    _prebuilt="$_android_system"
  else
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
  fi
  _prebuilt_valid=false
  if [ ! -f "$disk_file" ] && [ ! -f "$_prebuilt" ]; then
    _build_tmp="$IMAGES_DIR/${vm_name}-build"
    if [ -d "$_build_tmp" ]; then
      warn "image not ready for '$vm_name'; build appears in progress at $_build_tmp"
    else
      warn "image not found: $_prebuilt; build failed or type not supported"
    fi
    return
  fi

  _prebuilt_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
  if [ -f "$_prebuilt" ]; then
    if validate_qcow2_image "$_prebuilt" "pre-built image for ${vm_name}" "$_prebuilt_min_size"; then
      _prebuilt_valid=true
    else
      warn "pre-built image is invalid for '$vm_name': $_prebuilt"
      return
    fi
  fi

  vm_write_start_script "$vm_name" "$vm_display" "$vm_type" 'darwin-utm'
  vm_write_stop_script "$vm_name" "$vm_display" "$vm_type" 'darwin-utm'

  if [ "$dry_run" = false ]; then
    mkdir -p "$data_dir"
    if [ "$vm_type" = "Android" ]; then
      # Android guests do not run the vm-guest-credentials service, so no
      # credential markers apply; sync system/userdata/GSI into the bundle.
      if [ ! -f "$_android_userdata" ]; then
        warn "Android userdata image not found: $_android_userdata; run vm-build first"
        return
      fi
      _replace_runtime=false
      if [ -f "$disk_file" ] && ! validate_qcow2_image "$disk_file" "existing UTM runtime disk for ${vm_name}" "$_prebuilt_min_size"; then
        warn "existing Android runtime disk is invalid for '$vm_name'; replacing from pre-built image"
        rm -f "$disk_file"
        _replace_runtime=true
      fi
      if [ ! -f "$disk_file" ]; then
        if [ "$_prebuilt_valid" != true ]; then
          warn "cannot create the $vm_name Android runtime disk because no valid system image is available: $_android_system"
          return
        fi
        cp "$_android_system" "$disk_file"
        say "copied Android system image: $disk_file"
      elif [ "$_replace_runtime" = true ]; then
        warn "replacement was requested for '$vm_name' but the Android runtime disk still exists; leaving it untouched"
      else
        say "preserving existing Android system disk: $disk_file"
      fi
      # Bundle copies keep the manifest Android group filenames so UTM's
      # config.plist ImageName matches the on-disk file (single source: VMs.json).
      _userdata_file="$data_dir/$(jq -r ".VMs[$vm_index].Android.userdataImage" "$MANIFEST")"
      if [ -f "$_userdata_file" ] && ! validate_qcow2_image "$_userdata_file" "existing Android userdata disk for ${vm_name}" "$_prebuilt_min_size"; then
        warn "existing Android userdata disk is invalid for '$vm_name'; replacing from pre-built image"
        rm -f "$_userdata_file"
      fi
      if [ ! -f "$_userdata_file" ]; then
        cp "$_android_userdata" "$_userdata_file"
        say "copied Android userdata disk: $_userdata_file"
      else
        say "preserving existing Android userdata disk: $_userdata_file"
      fi
      _gsi_file="$data_dir/$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")"
      if [ -f "$_android_gsi" ]; then
        cp "$_android_gsi" "$_gsi_file"
        say "copied Android GSI image: $_gsi_file"
      elif [ -f "$_gsi_file" ]; then
        warn "Android GSI image removed from images dir; removing stale bundle copy: $_gsi_file"
        rm -f "$_gsi_file"
      fi
    else
      _replace_runtime=false
      if [ -f "$disk_file" ] && ! validate_qcow2_image "$disk_file" "existing UTM runtime disk for ${vm_name}" "$_prebuilt_min_size"; then
        warn "existing runtime disk is invalid for '$vm_name'; replacing from pre-built image"
        rm -f "$disk_file"
        _replace_runtime=true
      fi
      if [ -f "$disk_file" ] && ! vm_guest_credentials_marker_matches "$vm_guest_credentials_fingerprint" "$disk_credential_marker"; then
        warn "$vm_name runtime disk guest credential drift detected; replacing runtime disk from pre-built image"
        rm -f "$disk_file"
        _replace_runtime=true
      fi
      if [ -n "$_guest_config_fingerprint" ] && [ -f "$disk_file" ] \
        && ! vm_guest_config_marker_matches "$_guest_config_fingerprint" "$disk_config_marker"; then
        warn "$vm_name runtime disk guest config drift detected; replacing runtime disk from pre-built image"
        rm -f "$disk_file"
        _replace_runtime=true
      fi
      if [ ! -f "$disk_file" ]; then
        if [ "$_prebuilt_valid" != true ]; then
          warn "cannot replace the $vm_name runtime disk because no valid pre-built image is available: $_prebuilt"
          return
        fi
        cp "$_prebuilt" "$disk_file"
        say "copied pre-built disk image: $disk_file"
        resize_and_mark_image '' "$disk_credential_marker"
        if [ -n "$_guest_config_fingerprint" ]; then
          printf '%s\n' "$_guest_config_fingerprint" >"$disk_config_marker"
        fi
      elif [ "$_replace_runtime" = true ]; then
        warn "replacement was requested for '$vm_name' but the runtime disk still exists; leaving it untouched"
      else
        say "preserving existing disk image: $disk_file"
      fi
    fi
    cp "$_plist_template" "$config_plist"
    # Nix store files are read-only (mode 0444).  Make the bundle-local copy
    # writable so UTM can update the plist after import if needed.
    chmod +w "$config_plist"
    if [ "$bundle_exists" = true ]; then
      say "refreshed UTM bundle config: $bundle"
    else
      say "UTM bundle created: $bundle"
    fi
    if ! "$UTMCTL" list | awk 'NR > 1 { print $3 }' | grep -qxF "$vm_name"; then
      say "opening UTM bundle in place: $bundle"
      if open "$bundle"; then
        if wait_for_utm_registration "$vm_name"; then
          say "UTM VM opened and registered: $vm_name"
        else
          warn "UTM did not register VM '$vm_name' within timeout; open UTM and retry vm-setup"
        fi
      else
        warn "opening $bundle failed; ensure UTM can access the managed VM directory and retry"
      fi
    elif [ "$legacy_display_config" = true ] || [ "$template_drift_config" = true ]; then
      say "repairing stale UTM runtime registration for $vm_name"
      if re_register_utm_bundle "$vm_name" "$bundle"; then
        say "stale UTM registration repaired: $vm_name"
      fi
    else
      say "UTM VM already registered: $vm_name"
    fi
  else
    dry_run "create UTM bundle $bundle from $_plist_template"
  fi
}

# Libvirt VM setup callback for vm_for_each

vm_setup_libvirt() {
  local vm_name="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display disk_path disk_credential_marker disk_config_marker _prebuilt
  local _android_system _android_userdata _android_gsi
  local _guest_config_fingerprint

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")

  disk_path="$VM_DIR/${vm_name}.qcow2"
  disk_credential_marker="$(vm_guest_credentials_marker_path "$vm_name" "$disk_path")"
  disk_config_marker="$(vm_guest_config_marker_path "$vm_name" "$disk_path")"
  # WHY: only NixOS guests have a Nix-managed guest config to fingerprint.
  _guest_config_fingerprint=''
  if [ "$vm_type" = "NixOS" ]; then
    _guest_config_fingerprint="$(vm_guest_config_fingerprint)"
  fi

  say "configuring libvirt VM '$vm_display' (hosts: $vm_hosts)..."

  # Require pre-built images (built in phase 1).  Android uses the shared
  # android-* images (system + userdata, optional GSI) referenced directly by
  # the domain XML rather than a single <Name>.qcow2 runtime copy.  Image
  # filenames come from the manifest Android group (systemImage / userdataImage
  # / gsiImage).
  if [ "$vm_type" = "Android" ]; then
    _android_system="$IMAGES_DIR/$(jq -r ".VMs[$vm_index].Android.systemImage" "$MANIFEST")"
    _android_userdata="$IMAGES_DIR/$(jq -r ".VMs[$vm_index].Android.userdataImage" "$MANIFEST")"
    _android_gsi="$IMAGES_DIR/$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")"
    if [ ! -f "$_android_system" ] || [ ! -f "$_android_userdata" ]; then
      warn "Android images not found: $_android_system and $_android_userdata; skipping '$vm_name'"
      return
    fi
    _android_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
    if ! validate_qcow2_image "$_android_system" "Android system image for ${vm_name}" "$_android_min_size" \
      || ! validate_qcow2_image "$_android_userdata" "Android userdata disk for ${vm_name}" "$_android_min_size"; then
      warn "Android images are invalid for '$vm_name'"
      return
    fi
  else
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    _prebuilt_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
    if [ ! -f "$_prebuilt" ]; then
      warn "image not found: $_prebuilt; skipping '$vm_name'"
      return
    fi
    if ! validate_qcow2_image "$_prebuilt" "pre-built image for ${vm_name}" "$_prebuilt_min_size"; then
      warn "pre-built image is invalid for '$vm_name': $_prebuilt"
      return
    fi
  fi

  if [ "$dry_run" = false ]; then
    mkdir -p "$VM_DIR"
    if [ "$vm_type" = "Android" ]; then
      # The Android domain XML references the shared images directly; no
      # runtime copy and no guest-credential markers apply.
      say "Android images referenced directly by domain XML: $_android_system, $_android_userdata"
    else
      _replace_runtime=false
      if [ ! -f "$disk_path" ]; then
        _replace_runtime=true
      elif ! validate_qcow2_image "$disk_path" "existing libvirt runtime disk for ${vm_name}" "$_prebuilt_min_size"; then
        warn "existing libvirt runtime disk is invalid for '$vm_name'; replacing from pre-built image"
        rm -f "$disk_path"
        _replace_runtime=true
      elif ! vm_guest_credentials_marker_matches "$vm_guest_credentials_fingerprint" "$disk_credential_marker"; then
        warn "$vm_name runtime disk guest credential drift detected; replacing runtime disk from pre-built image"
        rm -f "$disk_path"
        _replace_runtime=true
      elif [ -n "$_guest_config_fingerprint" ] && ! vm_guest_config_marker_matches "$_guest_config_fingerprint" "$disk_config_marker"; then
        warn "$vm_name runtime disk guest config drift detected; replacing runtime disk from pre-built image"
        rm -f "$disk_path"
        _replace_runtime=true
      fi

      if [ "$_replace_runtime" = true ]; then
        cp "$_prebuilt" "$disk_path"
        say "disk image placed: $disk_path"
        resize_and_mark_image '' "$disk_credential_marker"
        if [ -n "$_guest_config_fingerprint" ]; then
          printf '%s\n' "$_guest_config_fingerprint" >"$disk_config_marker"
        fi
      else
        say "disk already exists: $disk_path"
      fi
    fi
  else
    if [ "$vm_type" = "Android" ]; then
      dry_run "use Android images in domain XML: $_android_system, $_android_userdata"
    else
      dry_run "copy $_prebuilt to $disk_path"
    fi
  fi

  # Define/update the libvirt domain from the Nix-generated XML (idempotent).
  # The file is installed at apply time by environment.etc in vms.nix.
  _xml_file="/etc/nucleus/vms/${vm_name}-domain.xml"
  if [ ! -f "$_xml_file" ]; then
    warn "domain XML not found at $_xml_file; apply the NixOS config first"
    return
  fi

  if [ "$dry_run" = false ]; then
    if virsh define "$_xml_file"; then
      say "VM '$vm_name' defined/updated in libvirt"
      vm_write_start_script "$vm_name" "$vm_display" "$vm_type" 'nixos-libvirt'
      vm_write_stop_script "$vm_name" "$vm_display" "$vm_type" 'nixos-libvirt'
    else
      warn "virsh define failed for '$vm_name'; check libvirtd status"
    fi
  else
    dry_run "virsh define $_xml_file"
  fi
}

# Phase 1 — Build images (if absent)

# Detect host architecture for nixos-generators format selection.
#   aarch64/arm64 → qcow-efi  (UTM on Apple Silicon uses UEFI/virt machine)
#   x86_64/amd64  → qcow      (BIOS mode, matches q35/SeaBIOS on x86_64 hosts)
case "$(uname -m)" in
  aarch64|arm64)
    _nixos_system='aarch64-linux'
    _nixos_format='qcow-efi'
    ;;
  *)
    _nixos_system='x86_64-linux'
    _nixos_format='qcow'
    ;;
esac

# vm_build_nixos NAME DISK_BYTES
#   Builds the NixOS guest image via nixos-generators (pinned as a flake
#   input in src/flake.nix).  On macOS this requires an aarch64-linux builder;
#   enable nix.linux-builder.enable in the macOS host config so the Nix daemon
#   delegates Linux derivations to the Virtualization.framework-backed builder
#   VM created by nix-darwin.  Most derivations are fetched from the binary
#   cache; hostname-specific ones (e.g. etc-hostname) are configuration-specific
#   and cannot be cached.
vm_build_nixos() {
  _name="$1"
  _disk_bytes="$2"
  _out="$IMAGES_DIR/${_name}.qcow2"
  _marker="$(vm_guest_credentials_marker_path "$_name")"
  _config_marker="$(vm_guest_config_marker_path "$_name")"
  _min_size="$(parse_size "$(jq -r ".VMs[] | select(.id == \"$_name\") | .minImageSize" "$MANIFEST")")"

  # WHY: rebuild when the guest config (guest.nix + imports + flake.lock)
  # drifts too, not just on credential drift; otherwise config edits silently
  # keep shipping the stale pre-built image.
  _config_fingerprint="$(vm_guest_config_fingerprint)" || return 1

  if [ -f "$_out" ]; then
    if validate_qcow2_image "$_out" "existing NixOS image" "$_min_size"; then
      if vm_guest_credentials_marker_matches "$vm_guest_credentials_fingerprint" "$_marker" \
        && vm_guest_config_marker_matches "$_config_fingerprint" "$_config_marker"; then
        say "NixOS image already built for the current guest credentials and config (owner=$vm_secret_owner, username=$vm_guest_username): $_out"
        return 0
      fi
      if vm_guest_config_marker_matches "$_config_fingerprint" "$_config_marker"; then
        say "NixOS image guest credential drift detected; rebuilding image: $_out"
      else
        say "NixOS image guest config drift detected; rebuilding image: $_out"
      fi
    else
      warn "existing NixOS image is invalid; rebuilding from scratch: $_out"
    fi
    if [ "$dry_run" = false ]; then
      rm -f "$_out" "$_marker" "$_config_marker"
    else
      dry_run "rm -f $_out $_marker $_config_marker"
      return 0
    fi
  fi

  _guest_nix="$VMS_DIR/nixos/guest.nix"
  if [ ! -f "$_guest_nix" ]; then
    error "nixos guest config not found: $_guest_nix"
    return 1
  fi

  say "building NixOS image (system=$_nixos_system, format=$_nixos_format)..."

  if [ "$dry_run" = true ]; then
    dry_run "nix run $REPO_ROOT/src#nixos-generators -- --format $_nixos_format --system $_nixos_system --configuration $_guest_nix -o <tmpdir>"
    return 0
  fi

  _tmpdir="$(mktemp -d)"
  _out_link="$_tmpdir/result"
  nix run "$REPO_ROOT/src#nixos-generators" -- \
    --format "$_nixos_format" \
    --system "$_nixos_system" \
    --configuration "$_guest_nix" \
    -o "$_out_link"

  # nixos-generators' -o flag expects a non-existent symlink path, not an
  # already-created directory. Use a child path inside our temp dir so the link
  # can be created atomically, then resolve either a direct symlink-to-file or a
  # symlinked directory containing the final QCOW2 image.
  # check-suppress:suppression_doc: symlink may not exist yet; readlink exits 1 for broken/missing links.
  _img="$(readlink "$_out_link" 2>/dev/null || true)"
  if [ -z "$_img" ] || [ ! -f "$_img" ]; then
    _img="$(find -L "$_out_link" -maxdepth 2 -name '*.qcow2' -print -quit 2>/dev/null)"
  fi
  if [ -z "$_img" ] || [ ! -e "$_img" ]; then
    error "nixos-generators produced no .qcow2 via $_out_link"
    rm -rf "$_tmpdir"
    return 1
  fi
  # -L follows symlinks so we copy the actual disk image bytes.
  cp -L "$_img" "$_out"
  chmod u+w "$_out"

  # WHY: nixos-generators defaults to a small virtual disk (~4 GiB) for qcow
  # outputs, but this repository declares guest disk sizes in VMs.json.
  # Resize here so the pre-built image matches the manifest contract used by
  # all runtime backends (UTM/libvirt/QEMU).
  if ! resize_and_mark_image "$_out" "$_marker" "$_disk_bytes"; then
    rm -rf "$_tmpdir"
    return 1
  fi
  printf '%s\n' "$_config_fingerprint" >"$_config_marker"

  rm -rf "$_tmpdir"
  say "NixOS image ready: $_out"
}

# download_windows_iso_mido CACHED_ISO EDITION
#   Downloads a Windows 11 ISO using vendor/qvm-create-windows-qube/windows/isos/mido.sh.
#   Mido is the secure Microsoft Windows Downloader for UNIX systems.
#   The EDITION parameter maps to a Mido media identifier.
#   Returns 0 on success, 1 on failure.
#   Requires curl in PATH.
#   Source: https://github.com/QubesOS/qvm-create-windows-qube
download_windows_iso_mido() {
  _mido_cached="$1"
  _mido_edition="$2"

  _mido_vendor_script="$REPO_ROOT/vendor/qvm-create-windows-qube/windows/isos/mido.sh"
  _mido_script="${NUCLEUS_MIDO_SCRIPT:-$_mido_vendor_script}"
  if [ ! -f "$_mido_script" ]; then
    error "mido.sh not found; run: git submodule update --init vendor/qvm-create-windows-qube"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl not found; required for Mido ISO download"
    return 1
  fi

  # Map edition to Mido media identifier.
  # Consumer multi-edition ISO (win11x64) covers Home/Pro/Edu; the
  # answer file selects the exact edition during unattended setup.
  # Source: Mido usage in windows/isos/mido.sh
  case "$(printf '%s' "$_mido_edition" | tr '[:upper:]' '[:lower:]')" in
    *enterprise*eval*) _mido_media='win11x64-enterprise-eval' ;;
    *) _mido_media='win11x64' ;;
  esac

  say "downloading Windows 11 ISO via Mido (media=$_mido_media)..."

  # Keep vendor submodules immutable by patching a temporary copy only.
  # This preserves a clean submodule tree while allowing fast compatibility
  # updates when Microsoft changes download-link HTML structures.
  _mido_patch_file="${NUCLEUS_MIDO_PATCH_FILE:-$REPO_ROOT/src/vms/windows/patches/mido-iso-link.patch}"
  _mido_script_tmp=''
  _mido_exec_script="$_mido_script"
  if [ -f "$_mido_patch_file" ]; then
    if command -v patch >/dev/null 2>&1; then
      _mido_script_tmp="$(mktemp -d)"
      _mido_exec_script="$_mido_script_tmp/mido.sh"
      cp "$_mido_script" "$_mido_exec_script"
      chmod 755 "$_mido_exec_script"
      if patch -s "$_mido_exec_script" "$_mido_patch_file" >/dev/null 2>&1; then
        say "applied runtime Mido patch: $_mido_patch_file"
      elif patch -s -R --dry-run "$_mido_exec_script" "$_mido_patch_file" >/dev/null 2>&1; then
        say "runtime Mido patch already present in source script; continuing"
      else
        error "runtime Mido patch failed to apply; update $_mido_patch_file for current vendor mido.sh before retrying"
        rm -rf "$_mido_script_tmp"
        _mido_script_tmp=''
        return 1
      fi
    else
      error "patch command is required for Mido runtime patching; install patch and retry"
      return 1
    fi
  else
    warn "runtime Mido patch file not found ($_mido_patch_file); continuing with vendor script"
  fi

  _mido_tmp="$(mktemp -d)"
  _mido_uuidgen_shim="$_mido_tmp/uuidgen"
  cat >"$_mido_uuidgen_shim" <<'EOF'
#!/bin/sh
if [ "${1-}" = "--random" ] || [ "${1-}" = "-r" ]; then
  shift
fi
exec /usr/bin/uuidgen "$@"
EOF
  chmod 755 "$_mido_uuidgen_shim"
  _mido_dir="$(CDPATH='' cd -- "$(dirname -- "$_mido_exec_script")" && pwd)"
  _mido_status=0
  (
    cd "$_mido_tmp"
    # Add Mido's directory to PATH to keep the download in _mido_tmp instead
    # of Mido's own directory.
    # WHY: mido.sh checks if its parent directory is in PATH; if so it stays
    # in PWD.  Without this, Mido cd-s to its own directory and writes the
    # ISO there instead of _mido_tmp.
    # Source: path detection logic at bottom of mido.sh
    PATH="${PATH}:${_mido_tmp}:${_mido_dir}" sh "$_mido_exec_script" "$_mido_media"
  ) || _mido_status=$?

  # Exit code 4 means verification failed but the ISO was downloaded as
  # .iso.UNVERIFIED (common for newer ISOs not yet in Mido's checksum list).
  # Accept the file and proceed; the caller can verify manually if desired.
  # Source: Mido exit codes in the ending_summary function of mido.sh
  if [ "$_mido_status" -ne 0 ] && [ "$_mido_status" -ne 4 ]; then
    error "Mido exited with code $_mido_status"
    rm -rf "$_mido_tmp"
    rm -rf "$_mido_script_tmp"
    return 1
  fi

  _mido_iso="$(find "$_mido_tmp" -maxdepth 1 \( -name '*.iso' -o -name '*.iso.UNVERIFIED' \) -print -quit 2>/dev/null)"
  if [ -z "$_mido_iso" ]; then
    error "Mido: no ISO found in temp dir after download"
    rm -rf "$_mido_tmp"
    rm -rf "$_mido_script_tmp"
    return 1
  fi

  mv "$_mido_iso" "$_mido_cached"
  rm -rf "$_mido_tmp"
  rm -rf "$_mido_script_tmp"
  say "Windows ISO downloaded: $_mido_cached"
  return 0
}

# download_windows_iso_fido CACHED_ISO EDITION
#   Downloads a Windows 11 ISO using vendor/Fido/Fido.ps1 (the same engine
#   that drives Rufus download automation).  Moves the downloaded ISO to
#   CACHED_ISO on success; returns 0 on success, 1 on failure.
#   Requires pwsh (PowerShell Core) in PATH.
#   Source: https://github.com/pbatard/Fido
download_windows_iso_fido() {
  _fido_cached="$1"
  _fido_edition="$2"

  _fido_script="$REPO_ROOT/vendor/Fido/Fido.ps1"
  if [ ! -f "$_fido_script" ]; then
    error "Fido.ps1 not found; run: git submodule update --init vendor/Fido"
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    say "pwsh not found; cannot use Fido for ISO auto-download"
    return 1
  fi

  say "downloading Windows 11 ISO via Fido (edition=$_fido_edition)..."
  # Run Fido in a temp dir so it downloads the ISO to a known location.
  # Fido.ps1 downloads to the working directory and returns the filename.
  # Source: https://github.com/pbatard/Fido#usage
  _fido_tmp="$(mktemp -d)"
  _fido_status=0
  (
    cd "$_fido_tmp"
    pwsh -NonInteractive -ExecutionPolicy Bypass \
      -File "$_fido_script" \
      -Win 11 -Ed "$_fido_edition" -Lang English -Arch x64 \
      -Download -NoPrompt
  ) || _fido_status=$?

  if [ "$_fido_status" -ne 0 ]; then
    error "Fido exited with code $_fido_status"
    rm -rf "$_fido_tmp"
    return 1
  fi

  # Use find rather than ls to safely handle any filename; Fido downloads one
  # ISO so sort-by-time is unnecessary.
  _fido_iso="$(find "$_fido_tmp" -maxdepth 1 -name '*.iso' | head -1)"
  if [ -z "$_fido_iso" ]; then
    error "Fido: no ISO found in temp dir after download"
    rm -rf "$_fido_tmp"
    return 1
  fi

  mv "$_fido_iso" "$_fido_cached"
  rm -rf "$_fido_tmp"
  say "Windows ISO downloaded: $_fido_cached"
  return 0
}

# download_windows_iso_fido_url_nonwindows CACHED_ISO EDITION
#   Resolves a Windows ISO URL via vendor/Fido/Fido.ps1 -GetUrl, then downloads
#   it with curl.  This is a non-Windows fallback for Darwin/Linux hosts when
#   Mido's consumer path fails.  A temporary script copy is patched at runtime
#   to bypass Fido's Windows-only guard; vendor sources remain unchanged.
#   Source: https://github.com/pbatard/Fido
download_windows_iso_fido_url_nonwindows() {
  _fido_cached="$1"
  _fido_edition="$2"

  _fido_script="$REPO_ROOT/vendor/Fido/Fido.ps1"
  if [ ! -f "$_fido_script" ]; then
    error "Fido.ps1 not found; run: git submodule update --init vendor/Fido"
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    error "pwsh not found; cannot use Fido URL fallback"
    return 1
  fi

  if ! command -v perl >/dev/null 2>&1; then
    error "perl not found; cannot patch temporary Fido script for non-Windows URL fallback"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl not found; required for Fido URL fallback download"
    return 1
  fi

  case "$(printf '%s' "$_fido_edition" | tr '[:upper:]' '[:lower:]')" in
    *enterprise*) _fido_ed_query='Enterprise' ;;
    *) _fido_ed_query='Home/Pro/Edu' ;;
  esac

  say "resolving Windows 11 ISO URL via Fido fallback (edition=$_fido_ed_query)..."

  _fido_tmp="$(mktemp -d)"
  _fido_exec="$_fido_tmp/Fido.ps1"
  _fido_output_file="$_fido_tmp/fido-url.out"
  cp "$_fido_script" "$_fido_exec"

  # Fido intentionally blocks non-Windows at runtime; patch only the temp copy.
  # This keeps vendor sources immutable while still allowing CLI URL resolution.
  _fido_patch_status=0
  perl -0pi -e 's/if \(\$winver -le 6\.1\) \{/if (\$false) {/g' "$_fido_exec" || _fido_patch_status=$?
  if [ "$_fido_patch_status" -ne 0 ]; then
    error "failed to patch temporary Fido script for non-Windows fallback (exit $_fido_patch_status)"
    rm -rf "$_fido_tmp"
    return 1
  fi

  _fido_status=0
  pwsh -NonInteractive -ExecutionPolicy Bypass \
    -File "$_fido_exec" \
    -Win 11 -Rel Latest -Ed "$_fido_ed_query" -Lang English -Arch x64 -PlatformArch x64 -GetUrl \
    >"$_fido_output_file" 2>&1 || _fido_status=$?
  cat "$_fido_output_file"

  if [ "$_fido_status" -ne 0 ]; then
    if grep -q '715-123130' "$_fido_output_file"; then
      error "Microsoft blocked automated ISO URL resolution (code 715-123130); retry later or use --windows-iso PATH"
    fi
    error "Fido URL resolver exited with code $_fido_status"
    rm -rf "$_fido_tmp"
    return 1
  fi

  _fido_url="$(grep -Eo 'https://[^[:space:]]+\.iso[^[:space:]]*' "$_fido_output_file" | tail -1)"
  if [ -z "$_fido_url" ]; then
    if grep -q '715-123130' "$_fido_output_file"; then
      error "Microsoft blocked automated ISO URL resolution (code 715-123130); retry later or use --windows-iso PATH"
    fi
    error "Fido URL resolver returned no ISO URL"
    rm -rf "$_fido_tmp"
    return 1
  fi

  say "downloading Windows ISO from resolved URL..."
  _fido_dl_status=0
  curl -fL -o "$_fido_cached" "$_fido_url" || _fido_dl_status=$?
  if [ "$_fido_dl_status" -ne 0 ]; then
    error "Fido URL fallback download failed (exit $_fido_dl_status); removing partial file"
    rm -f "$_fido_cached"
    rm -rf "$_fido_tmp"
    return 1
  fi

  rm -rf "$_fido_tmp"
  say "Windows ISO downloaded via Fido URL fallback: $_fido_cached"
  return 0
}

# vm_build_windows NAME DISK_BYTES
#   Builds the Windows 11 guest image using Packer and the Autounattend.xml
#   answer file at src/vms/windows/Autounattend.xml.
vm_build_windows() {
  _name="$1"
  _disk_bytes="$2"
  _edition="$3"
  _out="$IMAGES_DIR/${_name}.qcow2"
  _marker="$(vm_guest_credentials_marker_path "$_name")"
  _min_size="$(parse_size "$(jq -r ".VMs[] | select(.id == \"$_name\") | .minImageSize" "$MANIFEST")")"
  _hostfwd="$(jq -r --arg n "$_name" '[.VMs[] | select(.id == $n) | .portForwards[] | "hostfwd=tcp::\(.hostPort)-:\(.guestPort)"] | join(",")' "$MANIFEST")"
  _guest_hostname="$(jq -r --arg n "$_name" '.VMs[] | select(.id == $n) | .hostname // empty' "$MANIFEST")"

  if [ -f "$_out" ]; then
    if validate_qcow2_image "$_out" "existing Windows image" "$_min_size"; then
      if vm_guest_credentials_marker_matches "$vm_guest_credentials_fingerprint" "$_marker"; then
        say "Windows image already built for the current guest credentials (owner=$vm_secret_owner, username=$vm_guest_username): $_out"
        return 0
      fi
      say "Windows image guest credential drift detected; rebuilding image: $_out"
    fi
    warn "existing Windows image is invalid; rebuilding from scratch: $_out"
    rm -f "$_out" "$_marker"
  fi

  # Resolve the installer ISO: use --windows-iso if provided, otherwise try the
  # Windows.isoUrl field from VMs.json as a download source.
  _iso="$windows_iso"
  if [ -z "$_iso" ]; then
    say "Windows ISO fallback order: cached installer -> Windows.isoUrl -> downloader ($windows_iso_source mode)"
  fi

  # Resolve from cache first when --windows-iso is omitted.
  if [ -z "$_iso" ]; then
    _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
    if [ -f "$_cached_iso" ]; then
      say "using cached Windows installer: $_cached_iso"
      _iso="$_cached_iso"
    fi
  fi

  # Resolve via Windows.isoUrl next when allowed by source mode.
  if [ -z "$_iso" ] && [ "$windows_iso_source" != "mido" ]; then
    _iso_url="$(jq -r ".VMs[] | select(.id == \"$_name\") | .Windows.isoUrl // empty" "$MANIFEST")"
    if [ -n "$_iso_url" ]; then
      _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
      say "downloading Windows installer from Windows.isoUrl..."
      if [ "$dry_run" = false ]; then
        if run_with_backoff 'Windows.isoUrl download' curl -fL -o "$_cached_iso" "$_iso_url"; then
          _iso="$_cached_iso"
          say "Windows installer downloaded: $_cached_iso"
        else
          error "Windows.isoUrl download failed; remove $_cached_iso and retry"
          rm -f "$_cached_iso"
          return 1
        fi
      else
        dry_run "curl -fL -o $_cached_iso $_iso_url"
      fi
    fi
  fi

  # If still no ISO resolved, attempt automatic download fallback.
  # On Windows hosts: Mido first, then native Fido download fallback.
  # On macOS/Linux hosts: Fido URL resolver first (via pwsh -GetUrl), then Mido.
  # Source: https://github.com/QubesOS/qvm-create-windows-qube
  #         https://github.com/pbatard/Fido
  if [ -z "$_iso" ]; then
    _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
    if [ "$dry_run" = false ]; then
      case "$windows_iso_source" in
        url)
          error "windows-iso-source=url selected and no cached/Windows.isoUrl installer was resolved"
          ;;
        mido)
          if run_with_backoff 'Mido Windows ISO download' download_windows_iso_mido "$_cached_iso" "$_edition"; then
            _iso="$_cached_iso"
          fi
          ;;
        auto)
          _host_uname="$(uname -s)"
          case "$_host_uname" in
            MINGW*|MSYS*|CYGWIN*|Windows_NT)
              if run_with_backoff 'Mido Windows ISO download' download_windows_iso_mido "$_cached_iso" "$_edition"; then
                _iso="$_cached_iso"
              elif run_with_backoff 'Fido Windows ISO download' download_windows_iso_fido "$_cached_iso" "$_edition"; then
                _iso="$_cached_iso"
              fi
              ;;
            *)
              if run_with_backoff 'Fido URL resolver/download' download_windows_iso_fido_url_nonwindows "$_cached_iso" "$_edition"; then
                _iso="$_cached_iso"
              else
                warn "Fido URL fallback failed on $_host_uname; trying Mido as secondary fallback"
                if run_with_backoff 'Mido Windows ISO download' download_windows_iso_mido "$_cached_iso" "$_edition"; then
                  _iso="$_cached_iso"
                fi
              fi
              ;;
          esac
          ;;
      esac
    else
      case "$windows_iso_source" in
        url)
          dry_run "windows-iso-source=url selected; no downloader fallback will run"
          ;;
        mido)
          dry_run "would call vendor/qvm-create-windows-qube/windows/isos/mido.sh (with runtime patch copy)"
          ;;
        auto)
          dry_run "non-Windows hosts: Fido URL resolver then Mido; Windows hosts: Mido then Fido"
          ;;
      esac
    fi
  fi

  if [ -z "$_iso" ]; then
    error "--windows-iso PATH is required for Windows 11 builds"
    error "alternatively add 'Windows.isoUrl': '<url>' to the VMs.json windows entry"
    error "download from: https://www.microsoft.com/software-download/windows11"
    return 1
  fi

  if [ ! -f "$_iso" ]; then
    error "Windows ISO not found: $_iso"
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    error "packer not found; install via nixpkgs (pkgs.packer is in baseSharedPackages)"
    return 1
  fi

  _packer_dir="$VMS_DIR/windows"
  _tmp_out="$IMAGES_DIR/${_name}-build"
  _ssh_timeout='3h'
  if [ "$accelerator" = 'tcg' ]; then
    # WHY: x86_64 Windows setup under software emulation can take much longer
    # than hardware-accelerated paths.  On Apple Silicon (arm64 host emulating
    # x86_64 guest) QEMU tcg typically runs at 2-5% of native speed, meaning
    # Windows PE load + installation + OOBE + FirstLogonCommands can take
    # 10-30 real hours.  Use a very generous timeout that covers even the
    # slowest realistic tcg speed.
    _ssh_timeout='72h'
  fi

  say "building Windows 11 image (disk=$_disk_bytes bytes, accelerator=$accelerator)..."
  _display_backend=''
  if [ "$windows_headless" = 'false' ]; then
    # check-suppress:suppression_doc: QEMU binary may not be installed; display backend probe expected to fail.
  _display_help="$(qemu-system-x86_64 -display help || true)"
    for _display_candidate in cocoa gtk sdl spice-app curses; do
      if printf '%s\n' "$_display_help" | grep -Eiq "(^|[[:space:]])${_display_candidate}([[:space:]]|$)"; then
        _display_backend="$_display_candidate"
        break
      fi
    done
    if [ -z "$_display_backend" ]; then
      error "no supported QEMU display backend found for headful debugging; available backends:\n$_display_help"
      return 1
    fi
    say "debug mode enabled; running Windows Packer build headful (headless=false)"
    say "using QEMU display backend for debug run: $_display_backend"
  fi

  # WHY: This repository currently standardizes Windows guest runtime on BIOS
  # (see src/hosts/MacBook/vms.nix UEFIBoot=false and Autounattend.xml BIOS
  # partitioning). Keep build attempts BIOS-only by default to avoid landing in
  # OVMF Shell loops during EFI-first boot.
  _efi_code=''
  _efi_vars=''
  _qemu_share=''
  _qemu_bin="$(command -v qemu-system-x86_64 2>/dev/null || true)" # check-suppress:suppression_doc: qemu may not be installed; [ -n ] guard downstream handles the missing case.
  if [ -n "$_qemu_bin" ]; then
    _qemu_resolved="$_qemu_bin"
    _qemu_link_hops=0
    while [ "$_qemu_link_hops" -lt 8 ]; do
      # check-suppress:suppression_doc: symlink may not exist yet; readlink exits 1 for broken/missing links.
      _qemu_next="$(readlink "$_qemu_resolved" 2>/dev/null || true)"
      [ -n "$_qemu_next" ] || break
      _qemu_resolved="$_qemu_next"
      _qemu_link_hops=$((_qemu_link_hops + 1))
    done
    # check-suppress:suppression_doc: resolved path may not have a parent directory; probe expected to fail.
    _qemu_root="$(cd "$(dirname "$_qemu_resolved")/.." 2>/dev/null && pwd -P || true)"
    if [ -n "$_qemu_root" ] && [ -d "$_qemu_root/share/qemu" ]; then
      _qemu_share="$_qemu_root/share/qemu"
    fi
  fi

  for _efi_dir in \
    "$_qemu_share" \
    "/etc/profiles/per-user/${USER}/share/qemu" \
    "/Applications/UTM.app/Contents/Resources/qemu"
  do
    [ -n "$_efi_dir" ] || continue
    if [ -z "$_efi_code" ] && [ -f "$_efi_dir/edk2-x86_64-code.fd" ]; then
      _efi_code="$_efi_dir/edk2-x86_64-code.fd"
    fi
    if [ -z "$_efi_vars" ] && [ -f "$_efi_dir/edk2-i386-vars.fd" ]; then
      _efi_vars_size="$(wc -c < "$_efi_dir/edk2-i386-vars.fd" | tr -d '[:space:]')"
      if [ -n "$_efi_vars_size" ] && [ $((_efi_vars_size % 4096)) -eq 0 ]; then
        _efi_vars="$_efi_dir/edk2-i386-vars.fd"
      fi
    fi
  done

  _build_attempts='bios spacebar 2h'
  if [ "$accelerator" = 'tcg' ]; then
    _build_attempts='bios none 8h
bios spacebar 8h
bios alpha 8h
bios legacy 72h'
  else
    _build_attempts='bios none 30m
bios spacebar 2h
bios alpha 2h
bios legacy 3h'
  fi

  if [ -n "$_efi_code" ] && [ -n "$_efi_vars" ]; then
    say "EFI firmware detected ($_efi_code, $_efi_vars) but BIOS-only build policy is active"
  else
    say "EFI firmware not detected; using BIOS-only build attempts"
  fi

  if [ "$dry_run" = true ]; then
    dry_run "remove stale temporary output directory (if present): $_tmp_out"
    while IFS=' ' read -r _firmware_mode _boot_strategy _attempt_timeout; do
      [ -n "$_firmware_mode" ] || continue
      _pv="-var windows_iso=$_iso -var guest_username=$vm_guest_username -var guest_password=<redacted>"
      _pv="$_pv -var hostfwd=$_hostfwd -var guest_hostname=$_guest_hostname"
      _pv="$_pv -var autounattend_path=$VMS_DIR/windows/Autounattend.xml"
      _pv="$_pv -var accelerator=$accelerator"
      _pv="$_pv -var firmware_mode=$_firmware_mode -var boot_strategy=$_boot_strategy"
      _pv="$_pv -var ssh_timeout=$_attempt_timeout -var headless=$windows_headless"
      if [ "$windows_headless" = 'false' ]; then
        _pv="$_pv -var display_backend=$_display_backend"
      fi
      if [ "$_firmware_mode" = 'efi' ] && [ -n "$_efi_code" ] && [ -n "$_efi_vars" ]; then
        _pv="$_pv -var efi_firmware_code=$_efi_code -var efi_firmware_vars=$_efi_vars"
      fi
      _pv="$_pv -var disk_size=${_disk_bytes} -var output_directory=$_tmp_out"
      dry_run "cd $_packer_dir && packer build $_pv ."
    done <<EOF
$_build_attempts
EOF
    return 0
  fi

  if ! command -v perl >/dev/null 2>&1; then
    error "perl not found; required to render Windows Autounattend.xml guest credentials"
    return 1
  fi

  _packer_init_status=0
  (
    cd "$_packer_dir"
    packer init .
  ) || _packer_init_status=$?
  if [ "$_packer_init_status" -ne 0 ]; then
    error "Packer init for Windows VM '$_name' failed (exit $_packer_init_status)"
    return "$_packer_init_status"
  fi

  _packer_status=1
  _built_tmpdir=''
  while IFS=' ' read -r _firmware_mode _boot_strategy _attempt_timeout; do
    [ -n "$_firmware_mode" ] || continue

    say "Windows Packer attempt using firmware_mode=$_firmware_mode boot_strategy=$_boot_strategy (ssh_timeout=$_attempt_timeout)..."

    # WHY: Packer qemu builder requires a non-existent output_directory.
    # Use a fresh temp tree per attempt so a failed try cannot poison the next
    # firmware/boot-strategy combination.
    _attempt_tmpdir="$(mktemp -d "${IMAGES_DIR}/.${_name}.${_firmware_mode}.${_boot_strategy}.XXXXXX")"
    _tmp_out="$_attempt_tmpdir/output"
    _packer_log="$_attempt_tmpdir/packer.log"
    _autounattend_rendered="$_attempt_tmpdir/Autounattend.xml"
    perl -pe "s/__NUCLEUS_GUEST_USERNAME__/${vm_guest_username}/g; s/__NUCLEUS_GUEST_PASSWORD__/${vm_guest_password}/g; s/__GUEST_HOSTNAME__/$_guest_hostname/g" \
      "$VMS_DIR/windows/Autounattend.xml" >"$_autounattend_rendered"
    say "writing Packer debug log for this attempt: $_packer_log"

    _attempt_status=0
    if [ "$_firmware_mode" = 'efi' ]; then
      (
        cd "$_packer_dir"
        PACKER_LOG=1 PACKER_LOG_PATH="$_packer_log" packer build \
          -var "windows_iso=$_iso" \
          -var "guest_username=$vm_guest_username" \
          -var "guest_password=$vm_guest_password" \
          -var "hostfwd=$_hostfwd" \
          -var "guest_hostname=$_guest_hostname" \
          -var "autounattend_path=$_autounattend_rendered" \
          -var "accelerator=$accelerator" \
          -var "firmware_mode=$_firmware_mode" \
          -var "boot_strategy=$_boot_strategy" \
          -var "ssh_timeout=$_attempt_timeout" \
          -var "headless=$windows_headless" \
          ${_display_backend:+-var "display_backend=$_display_backend"} \
          -var "efi_firmware_code=$_efi_code" \
          -var "efi_firmware_vars=$_efi_vars" \
          -var "disk_size=${_disk_bytes}" \
          -var "output_directory=$_tmp_out" \
          .
      ) || _attempt_status=$?
    else
      (
        cd "$_packer_dir"
        PACKER_LOG=1 PACKER_LOG_PATH="$_packer_log" packer build \
          -var "windows_iso=$_iso" \
          -var "guest_username=$vm_guest_username" \
          -var "guest_password=$vm_guest_password" \
          -var "hostfwd=$_hostfwd" \
          -var "guest_hostname=$_guest_hostname" \
          -var "autounattend_path=$_autounattend_rendered" \
          -var "accelerator=$accelerator" \
          -var "firmware_mode=$_firmware_mode" \
          -var "boot_strategy=$_boot_strategy" \
          -var "ssh_timeout=$_attempt_timeout" \
          -var "headless=$windows_headless" \
          ${_display_backend:+-var "display_backend=$_display_backend"} \
          -var "disk_size=${_disk_bytes}" \
          -var "output_directory=$_tmp_out" \
          .
      ) || _attempt_status=$?
    fi

    if [ "$_attempt_status" -eq 0 ]; then
      _packer_status=0
      _built_tmpdir="$_attempt_tmpdir"
      break
    fi

    if [ "$_attempt_status" -eq 130 ] || [ "$_attempt_status" -eq 143 ]; then
      warn "Windows Packer attempt cancelled (exit $_attempt_status); aborting retry matrix"
      _packer_status="$_attempt_status"
      rm -rf "$_attempt_tmpdir"
      break
    fi

    warn "Windows Packer attempt failed for firmware_mode=$_firmware_mode boot_strategy=$_boot_strategy (exit $_attempt_status); trying next strategy"
    if [ -f "$_packer_log" ]; then
      warn "last 60 lines from failed Packer log ($_packer_log):"
      tail -n 60 "$_packer_log" >&2
    fi
    _packer_status="$_attempt_status"
    rm -rf "$_attempt_tmpdir"
  done <<EOF
$_build_attempts
EOF

  if [ "$_packer_status" -ne 0 ]; then
    error "Packer build for Windows VM '$_name' failed (exit $_packer_status)"
    return "$_packer_status"
  fi
  _built="$_built_tmpdir/output/windows.qcow2"
  if [ ! -f "$_built" ]; then
    error "Packer did not produce $_built"
    rm -rf "$_built_tmpdir"
    return 1
  fi

  mv "$_built" "$_out"
  rm -rf "$_built_tmpdir"

  if ! validate_qcow2_image "$_out" 'newly built Windows image' "$_min_size"; then
    error "Windows image validation failed after build; removing $_out"
    rm -f "$_out"
    return 1
  fi

  resize_and_mark_image '' "$_marker"
  say "Windows 11 image ready: $_out"
}

# vm_build_macos NAME DISK_BYTES RAM_BYTES CPUS MACOS_VERSION
#   Builds the macOS guest VM using the Packer Tart plugin.  Requires tart
#   and packer to be installed; only runs on Darwin hosts (Tart uses Apple
#   Virtualization.framework which is not available on other platforms).
#   The resulting VM is stored in ~/virtual machines/.tart/vms/<name>/ (via
#   the ~/.tart symlink created by ensure_tart_vm_dir).
#   Source: https://github.com/cirruslabs/packer-plugin-tart
vm_build_macos() {
  _name="$1"
  _disk_bytes="$2"
  _ram_bytes="$3"
  _cpus="$4"
  _macos_version="$5"
  _marker="$(vm_guest_credentials_marker_path "$_name")"

  # Tart requires Apple Virtualization.framework — macOS host only.
  if [ "$(uname -s)" != "Darwin" ]; then
    say "macOS guest build requires a macOS host (Tart uses Virtualization.framework); skipping"
    return 0
  fi

  if ! command -v tart >/dev/null 2>&1; then
    error "tart not found; install with: brew install cirruslabs/cli/tart"
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    error "packer not found; install via nixpkgs (pkgs.packer)"
    return 1
  fi

  # Check if tart VM already exists.
  if tart list 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$_name"; then
    if vm_guest_credentials_marker_matches "$vm_guest_credentials_fingerprint" "$_marker"; then
      say "tart VM '$_name' already exists for the current guest credentials (owner=$vm_secret_owner, username=$vm_guest_username)"
      return 0
    fi

    say "macOS guest credential drift detected; rebuilding tart VM '$_name'"
    if ! tart delete "$_name"; then
      error "failed to delete stale tart VM '$_name' before rebuild"
      return 1
    fi
    rm -f "$_marker"
  fi

  _packer_dir="$VMS_DIR/macos"
  # Tart accepts only whole GiB: `tart create --disk-size` is decimal GB
  # (UInt64 * 1000^3) and the Packer Tart plugin passes memory as GiB*1024 MB
  # to `tart set --memory`.  Round UP from exact manifest bytes so allocated
  # capacity never under-allocates the declared size.
  _disk_gib="$(( (_disk_bytes + 999999999) / 1000000000 ))"
  _mem_gib="$(( (_ram_bytes + 1073741823) / 1073741824 ))"

  say "building macOS $_macos_version VM via Packer Tart (disk=$_disk_gib GiB, mem=$_mem_gib GiB, cpus=$_cpus)..."

  if [ "$dry_run" = true ]; then
    dry_run "cd $_packer_dir && packer build -var vm_name=$_name -var macos_version=$_macos_version -var guest_username=$vm_guest_username -var guest_password=<redacted> -var vm_hostname=$NUCLEUS_VM_GUEST_HOSTNAME -var disk_size_gib=$_disk_gib -var memory_gib=$_mem_gib -var cpus=$_cpus ."
    return 0
  fi

  _packer_status=0
  (
    cd "$_packer_dir"
    packer init .
    packer build \
      -var "vm_name=$_name" \
      -var "macos_version=$_macos_version" \
      -var "guest_username=$vm_guest_username" \
      -var "guest_password=$vm_guest_password" \
      -var "vm_hostname=$NUCLEUS_VM_GUEST_HOSTNAME" \
      -var "disk_size_gib=$_disk_gib" \
      -var "memory_gib=$_mem_gib" \
      -var "cpus=$_cpus" \
      .
  ) || _packer_status=$?

  if [ "$_packer_status" -ne 0 ]; then
    error "Packer build for macOS VM '$_name' failed (exit $_packer_status)"
    return "$_packer_status"
  fi
  resize_and_mark_image '' "$_marker"
  say "macOS VM '$_name' built and registered in tart"
}

# prune_stale_build_dirs
#   Removes orphaned dot-prefixed Packer build temporary directories that may
#   have been left behind by interrupted or crashed builds.
prune_stale_build_dirs() {
  if [ ! -d "$IMAGES_DIR" ]; then
    return 0
  fi

  for _dir in "$IMAGES_DIR"/.??*; do
    if [ "$_dir" = "$IMAGES_DIR/." ] || [ "$_dir" = "$IMAGES_DIR/.." ]; then
      continue
    fi
    if [ -d "$_dir" ]; then
      say "removing stale temporary build directory: $_dir"
      rm -rf "$_dir"
    fi
  done
}

vm_build_images() {
  prune_stale_build_dirs
  vm_for_each vm_build_one_image
}

# macOS / Tart (macOS guests)

# vm_setup_tart_vms — Phase 2 provisioning checks for macOS-type VM guests.
#   The Packer Tart build already registered the VM in tart's store; this
#   function validates registration and reports runtime entry points.
#   Source: https://github.com/cirruslabs/tart
vm_setup_tart_vms() {
  if ! command -v tart >/dev/null 2>&1; then
    say "tart not found; skipping macOS VM start-script generation"
    return
  fi

  vm_for_each vm_setup_tart
}

# macOS / UTM (NixOS and Windows guests on macOS host)

vm_setup_utm_vms() {
  if [ ! -d /Applications/UTM.app ]; then
    say "UTM not found at /Applications/UTM.app; skipping macOS VM provisioning"
    return
  fi

  vm_for_each vm_setup_utm

  say "macOS VM setup complete"
}

# NixOS / libvirt

vm_setup_libvirt_vms() {
  if ! command -v virsh >/dev/null 2>&1; then
    say "virsh not found in PATH; libvirtd may not be enabled yet"
    say "apply the NixOS configuration first so vms.nix activates libvirtd"
    return
  fi

  # Ensure the libvirt default network is started so VMs can reach the host.
  if virsh net-list --all 2>/dev/null | grep -q "default"; then
    if ! virsh net-list 2>/dev/null | grep -q "default.*active"; then
      say "starting libvirt default network..."
      if ! run_cmd virsh net-start default; then
        warn "failed to start libvirt default network; guest networking may be unavailable until it is started manually"
      fi
      if ! run_cmd virsh net-autostart default; then
        warn "failed to mark libvirt default network for autostart; future boots may require manual recovery"
      fi
    fi
  fi

  vm_for_each vm_setup_libvirt

  say "NixOS VM setup complete; use the generated start-<name> helpers (or virt-manager) to start VMs"
}

# Windows / QEMU

# vm_setup_windows_qemu — Callback for vm_for_each on Windows. Writes a QEMU
#   start script for Android and Windows VMs on the Windows host.
vm_setup_windows_qemu() {
  local vm_name="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")

  case "$vm_type" in
    Android|Windows)
      say "configuring QEMU start scripts for '$vm_display' on Windows..."
      vm_write_start_script "$vm_name" "$vm_display" "$vm_type" 'windows-qemu'
      vm_write_stop_script "$vm_name" "$vm_display" "$vm_type" 'windows-qemu'
      ;;
    *)
      say "skipping script generation for '$vm_display' on Windows (type $vm_type not supported via QEMU)"
      ;;
  esac
}

vm_setup_windows_qemu_vms() {
  vm_for_each vm_setup_windows_qemu
  say "Windows VM setup complete; use the generated start-<name> scripts to start VMs"
}

# Garbage collection for non-provisioned VM artifacts

# vm_gc_vms — Top-level GC dispatcher.  Called from the vm.sh main flow
#   when --gc is passed.  Removes VM artifacts (Tart VMs, UTM bundles,
#   libvirt domains, disk images, credential markers) for VMs not in the
#   expected set.  By default only entries absent from VMs.json entirely are
#   cleared; disabled entries are preserved unless --gc-disabled is passed,
#   which narrows the expected set to enabled-and-host-matched VMs.
vm_gc_vms() {
  # WHY: default GC keeps disabled entries; only names absent from the
  # manifest are orphans.  --gc-disabled opts into clearing disabled entries.
  if [ "$gc_disabled_mode" = true ]; then
    _gcv_expected="$(vm_get_expected_vm_names)" || return
    say "GC — including disabled VM entries (--gc-disabled)..."
  else
    _gcv_expected="$(vm_get_manifest_vm_names)" || return
  fi

  say "GC — scanning for non-provisioned VM artifacts..."
  if [ "$dry_run" = true ]; then
    dry_run "GC mode enabled — inspecting artifacts..."
  fi

  case "$(uname -s)" in
    Darwin)
      gc_tart_vms "$_gcv_expected"
      gc_utm_bundles "$_gcv_expected"
      ;;
    Linux)
      if [ -f /etc/NIXOS ]; then
        gc_libvirt_vms "$_gcv_expected"
      fi
      ;;
  esac

  vm_gc_orphan_disks "$_gcv_expected"
  vm_gc_orphan_markers "$_gcv_expected"

  say "GC — done"
}

# gc_tart_vms EXPECTED_NAMES — Remove Tart VMs not in the expected set.
gc_tart_vms() {
  _gct_expected="$1"
  command -v tart >/dev/null 2>&1 || return

  tart list 2>/dev/null | awk 'NR>1{print $2}' | while IFS= read -r _gct_name; do
    [ -z "$_gct_name" ] && continue
    if ! printf '%s\n' "$_gct_expected" | grep -qxF "$_gct_name"; then
      say "GC — removing non-provisioned Tart VM: $_gct_name"
      if [ "$dry_run" = false ]; then
        tart delete "$_gct_name"
      fi
    fi
  done
}

# gc_utm_bundles EXPECTED_NAMES — Remove UTM bundles not in the expected set.
gc_utm_bundles() {
  _gcu_expected="$1"
  [ -d /Applications/UTM.app ] || return

  for _gcu_bundle in "$VM_DIR"/*.utm/; do
    [ -d "$_gcu_bundle" ] || continue
    _gcu_name="$(basename "$_gcu_bundle" .utm)"
    if ! printf '%s\n' "$_gcu_expected" | grep -qxF "$_gcu_name"; then
      say "GC — removing non-provisioned UTM bundle: $_gcu_bundle"
      if [ "$dry_run" = false ]; then
        rm -rf "$_gcu_bundle"
      fi
    fi
  done
}

# gc_libvirt_vms EXPECTED_NAMES — Remove libvirt domains not in the expected set.
gc_libvirt_vms() {
  _gcl_expected="$1"
  command -v virsh >/dev/null 2>&1 || return

  virsh list --all --name 2>/dev/null | while IFS= read -r _gcl_name; do
    [ -z "$_gcl_name" ] && continue
    if ! printf '%s\n' "$_gcl_expected" | grep -qxF "$_gcl_name"; then
      say "GC — removing non-provisioned libvirt domain: $_gcl_name"
      if [ "$dry_run" = false ]; then
        # check-suppress:suppression_doc: VM may not exist; virsh undefine exits 1 for non-existent domains.
        virsh undefine "$_gcl_name" 2>/dev/null || true
      fi
    fi
  done
}

# vm_gc_orphan_disks EXPECTED_NAMES — Remove disk images not in the expected set.
vm_gc_orphan_disks() {
  _gcod_expected="$1"

  for _gcod_dir in "$VM_DIR" "$IMAGES_DIR"; do
    [ -d "$_gcod_dir" ] || continue
    for _gcod_path in "$_gcod_dir"/*.qcow2; do
      [ -f "$_gcod_path" ] || continue
      _gcod_name="$(basename "$_gcod_path" .qcow2)"
      if ! printf '%s\n' "$_gcod_expected" | grep -qxF "$_gcod_name"; then
        say "GC — removing non-provisioned disk image: $_gcod_path"
        if [ "$dry_run" = false ]; then
          rm -f "$_gcod_path"
        fi
      fi
    done
  done
}

# vm_gc_orphan_markers EXPECTED_NAMES — Remove guest marker files (credential
#   and config fingerprints) whose disk image no longer exists.
vm_gc_orphan_markers() {
  _gcom_expected="$1"

  for _gcom_dir in "$VM_DIR" "$IMAGES_DIR"; do
    [ -d "$_gcom_dir" ] || continue
    for _gcom_marker in "$_gcom_dir"/*.vm-guest-credentials-sha256 "$_gcom_dir"/*.vm-guest-config-sha256; do
      [ -f "$_gcom_marker" ] || continue
      case "$_gcom_marker" in
        *.vm-guest-credentials-sha256) _gcom_base="${_gcom_marker%.vm-guest-credentials-sha256}" ;;
        *) _gcom_base="${_gcom_marker%.vm-guest-config-sha256}" ;;
      esac
      if [ ! -f "$_gcom_base" ]; then
        say "GC — removing orphaned guest marker: $_gcom_marker"
        if [ "$dry_run" = false ]; then
          rm -f "$_gcom_marker"
        fi
      fi
    done
  done
}
