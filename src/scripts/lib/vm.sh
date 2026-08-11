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

# copy_with_reflink SRC DST
#   Copy SRC to DST using a CoW reflink when supported (APFS, btrfs, xfs);
#   otherwise fall back to plain cp. Uses cp -L to follow symlink sources.
copy_with_reflink() {
  _cwr_src="$1"
  _cwr_dst="$2"
  if cp -L --reflink=auto "$_cwr_src" "$_cwr_dst" 2>/dev/null; then
    return 0
  fi
  cp -L "$_cwr_src" "$_cwr_dst"
}

# vm_init — Initialize all shared config variables from explicit
# positional parameters. Called after sourcing so shellcheck can trace every
# variable assignment through the function call.
vm_init() {
  REPO_ROOT="$1"
  VM_DIR="$2"
  SRC_DIR="$3"
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
  force="${24}"
  gc_data_mode="${25}"
}

VM_SYSTEM_IMAGE='system image.qcow2'
VM_PACKER_BUILD_DIR='Packer'
VM_ANDROID_RECOVERY_IMG='recovery userdebug.img'
VM_ANDROID_RECOVERY_TAG='recovery userdebug.tag.json'
export VM_ANDROID_BOOT_IMG='boot.img'
export VM_ANDROID_BOOT_TAG='boot.tag.json'
export VM_ANDROID_MAGISK_APK='Magisk.apk'
export VM_ANDROID_BOOT_MAGISK_PATCHED='boot Magisk patched.img'
export VM_ANDROID_GAPPS_ZIP='GApps.zip'
export VM_ANDROID_MAGISK_PATCH_KIT='Magisk patch kit'
VM_ANDROID_LINEAGE_ZIP='Lineage download.zip'
VM_ANDROID_LINEAGE_EXTRACT='Lineage extract'
VM_ANDROID_GSI_DOWNLOAD_ZIP='GSI download.zip'
VM_WINDOWS_INSTALLER_ISO='installer.iso'
export VM_WINDOWS_VIRTIO_ISO='virtio guest tools.iso'
VM_TYPE_MARKER_BASE='system image'

vm_type_src_dir() {
  printf '%s/%s\n' "$SRC_DIR" "$1"
}

vm_src_path() {
  printf '%s/%s\n' "$(vm_type_src_dir "$1")" "$2"
}

vm_system_image_rel_path() {
  printf '../src/%s/%s\n' "$1" "$VM_SYSTEM_IMAGE"
}

vm_ensure_type_src_dirs() {
  local _vetsd_type
  while IFS= read -r _vetsd_type; do
    [ -n "$_vetsd_type" ] || continue
    mkdir -p "$(vm_type_src_dir "$_vetsd_type")"
  done < <(jq -r '.VMs[].type' "$MANIFEST" | sort -u)
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
  if [ -f "$TEMPLATES_DIR/README.md" ]; then
    sed -e "s|__VM_DIR_DISPLAY__|$_wvdr_vm_dir_short|g" \
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

# ensure_tart_vm_dir
#   Co-locates Tart's VM store inside the managed ~/virtual machines directory
#   by symlinking ~/.tart → ~/virtual machines/tart so Tart artifacts (VMs and
#   OCI cache) stay alongside UTM bundles in one tree for unified backup.
#   Only runs on Darwin; Tart uses Apple's Virtualization.framework.
ensure_tart_vm_dir() {
  _etd_target="$VM_DIR/tart"
  _etd_default="$HOME/.tart"

  mkdir -p "$_etd_target"

  if [ -L "$_etd_default" ]; then
    # check-suppress:suppression_doc: symlink may not exist yet; readlink exits 1 for broken/missing links.
    _etd_current="$(readlink "$_etd_default" 2>/dev/null || true)"
    if [ "$_etd_current" = "$_etd_target" ]; then
      say "tart storage already linked: $_etd_default -> $_etd_target"
      return 0
    fi
    echo "tart: $_etd_default is a symlink to $_etd_current (expected $_etd_target); fix manually and retry" >&2
    return 1
  fi

  if [ -e "$_etd_default" ]; then
    echo "tart: $_etd_default exists and is not a symlink to $_etd_target; fix manually and retry" >&2
    return 1
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
  [ -n "$NUCLEUS_HOST" ] || return 1
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

  _vqi_size_bytes="$(wc -c <"$_vqi_path" | tr -d '[:space:]')"
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

# vm_resolve_guest_ssh_public_key USERNAME REPO_ROOT
#   Prints the first readable SSH public key under ~/.ssh per
#   src/modules/vm-guest-ssh-public-key-paths.json. Static id_*.pub paths are
#   tried before username templates (ssh_personal_{username}.pub, etc.).
#   Returns 1 when no key exists.
vm_resolve_guest_ssh_public_key() {
  _vrgspk_username="$1"
  _vrgspk_repo_root="$2"

  if [ -z "$_vrgspk_repo_root" ]; then
    error 'vm_resolve_guest_ssh_public_key requires repo root'
    return 1
  fi

  _vrgspk_manifest="$_vrgspk_repo_root/src/modules/vm-guest-ssh-public-key-paths.json"
  if [ ! -f "$_vrgspk_manifest" ]; then
    error "guest SSH public key manifest not found: $_vrgspk_manifest"
    return 1
  fi

  _vrgspk_ssh_dir="$HOME/.ssh"

  while IFS= read -r _vrgspk_rel; do
    [ -z "$_vrgspk_rel" ] && continue
    _vrgspk_key_path="$_vrgspk_ssh_dir/$_vrgspk_rel"
    if [ -f "$_vrgspk_key_path" ] && [ -r "$_vrgspk_key_path" ]; then
      cat "$_vrgspk_key_path"
      return 0
    fi
  done < <(jq -r '.staticRelativePaths[]' "$_vrgspk_manifest")

  if [ -n "$_vrgspk_username" ]; then
    while IFS= read -r _vrgspk_tpl; do
      [ -z "$_vrgspk_tpl" ] && continue
      _vrgspk_rel="${_vrgspk_tpl//\{username\}/$_vrgspk_username}"
      _vrgspk_key_path="$_vrgspk_ssh_dir/$_vrgspk_rel"
      if [ -f "$_vrgspk_key_path" ] && [ -r "$_vrgspk_key_path" ]; then
        cat "$_vrgspk_key_path"
        return 0
      fi
    done < <(jq -r '.usernameRelativePathTemplates[]' "$_vrgspk_manifest")
  fi

  return 1
}

# vm_type_config_marker_path TYPE
#   Returns the sidecar marker path storing the type-config fingerprint for
#   the type system image (src/<type>/system image.vm-type-config-sha256).
#   WHY: the type system image is identity-free and shared by every VM of the
#   type; the marker lives next to it (src/<type>/), not under a per-VM name.
vm_type_config_marker_path() {
  local _vtcmp_type="$1"
  vm_src_path "$_vtcmp_type" "${VM_TYPE_MARKER_BASE}.vm-type-config-sha256"
}

# vm_type_config_marker_matches EXPECTED_FINGERPRINT MARKER_PATH
#   Returns 0 when MARKER_PATH exists and equals EXPECTED.
vm_type_config_marker_matches() {
  local _vtcmm_expected="$1" _vtcmm_marker="$2" _vtcmm_actual
  if [ ! -f "$_vtcmm_marker" ]; then
    return 1
  fi
  _vtcmm_actual="$(tr -d '\r\n' <"$_vtcmm_marker")"
  [ "$_vtcmm_actual" = "$_vtcmm_expected" ]
}

# vm_provision_marker_path DISK_PATH
#   Returns the sidecar marker path storing the per-VM provision fingerprint
#   for the writable data disk DISK_PATH (data/<id>.qcow2.vm-provision-sha256).
vm_provision_marker_path() {
  local _vpmp_disk="$1"
  printf '%s.vm-provision-sha256\n' "$_vpmp_disk"
}

# vm_provision_marker_matches EXPECTED_FINGERPRINT MARKER_PATH
#   Returns 0 when MARKER_PATH exists and equals EXPECTED.
vm_provision_marker_matches() {
  local _vpmm_expected="$1" _vpmm_marker="$2" _vpmm_actual
  if [ ! -f "$_vpmm_marker" ]; then
    return 1
  fi
  _vpmm_actual="$(tr -d '\r\n' <"$_vpmm_marker")"
  [ "$_vpmm_actual" = "$_vpmm_expected" ]
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

# vm_type_config_fingerprint TYPE
#   Prints a SHA-256 fingerprint of the type's build config inputs: the
#   type-scoped config files under src/vms/<type>/ (contents, not just paths)
#   plus src/flake.lock.  NixOS hashes base-guest.nix and every resolved src/
#   import, the formats/ and disk-image/ trees; Windows hashes Autounattend.xml,
#   patches/ and packer.pkr.hcl; macOS hashes packer.pkr.hcl.  WHY: flake.lock
#   pins the nixos-generators/Packer revisions.  Returns 1 when no SHA-256
#   tool is available or a resolved import is missing.
vm_type_config_fingerprint() {
  local _vtcf_type="$1" _vtcf_import _vtcf_imports _vtcf_missing
  case "$_vtcf_type" in
  NixOS | Windows | macOS) ;;
  *)
    error "no type-config fingerprint definition for VM type: $_vtcf_type"
    return 1
    ;;
  esac
  if [ "$_vtcf_type" = "NixOS" ]; then
    _vtcf_imports="$(grep -oE '(\.\./)+src/[A-Za-z0-9_./-]+\.nix' "$VMS_DIR/NixOS/base-guest.nix" | sort -u)"
    _vtcf_missing=0
    for _vtcf_import in $_vtcf_imports; do
      if [ ! -f "$VMS_DIR/NixOS/$_vtcf_import" ]; then
        error "type-config fingerprint: missing import for NixOS base: $VMS_DIR/NixOS/$_vtcf_import"
        _vtcf_missing=1
      fi
    done
    if [ "$_vtcf_missing" -ne 0 ]; then
      return 1
    fi
  fi
  {
    case "$_vtcf_type" in
    NixOS)
      cat "$VMS_DIR/NixOS/base-guest.nix"
      for _vtcf_import in $_vtcf_imports; do
        cat "$VMS_DIR/NixOS/$_vtcf_import"
      done
      if [ -d "$VMS_DIR/NixOS/formats" ]; then
        find "$VMS_DIR/NixOS/formats" -type f -exec cat {} +
      fi
      if [ -d "$VMS_DIR/NixOS/disk-image" ]; then
        find "$VMS_DIR/NixOS/disk-image" -type f -exec cat {} +
      fi
      ;;
    Windows)
      cat "$VMS_DIR/Windows/Autounattend.xml"
      if [ -d "$VMS_DIR/Windows/patches" ]; then
        find "$VMS_DIR/Windows/patches" -type f -exec cat {} +
      fi
      cat "$VMS_DIR/Windows/packer.pkr.hcl"
      ;;
    macOS)
      cat "$VMS_DIR/macOS/packer.pkr.hcl"
      ;;
    esac
    if [ -f "$REPO_ROOT/src/flake.lock" ]; then
      cat "$REPO_ROOT/src/flake.lock"
    fi
  } | vm_sha256_input
}

# vm_type_image_fingerprint TYPE
#   Prints the fingerprint gating the type system image rebuild: the
#   type-config fingerprint, plus the guest credential fingerprint for
#   Windows and macOS.  WHY: POSIX NixOS builds (nixos-generators) are
#   identity-free, so config alone gates the type image; Windows/macOS builds
#   bake guest identity (Autounattend.xml tokens, Tart packer vars) into the
#   base image, and macOS has no per-VM injection path at all, so the type
#   marker must track credentials for those types (documented exception to the
#   identity-free type image invariant).
vm_type_image_fingerprint() {
  local _vtif_type="$1" _vtif_config
  _vtif_config="$(vm_type_config_fingerprint "$_vtif_type")" || return 1
  if [ "$_vtif_type" = "NixOS" ]; then
    printf '%s\n' "$_vtif_config"
  else
    printf '%s\n%s\n' "$_vtif_config" "$vm_guest_credentials_fingerprint" | vm_sha256_input
  fi
}

# vm_provision_fingerprint NAME
#   Prints the per-VM provision fingerprint for the data disk of manifest VM
#   NAME: the contents of every file under src/vms/guests/<name>/ (the per-VM
#   guest identity), the provision-relevant manifest fields (hostname,
#   shareDevDir, portForwards), and the guest credential fingerprint.  WHY:
#   this is the drift key for in-place re-injection — any change to per-VM
#   identity, wiring, or credentials invalidates it.
vm_provision_fingerprint() {
  local _vpf_name="$1" _vpf_guest_dir="$VMS_DIR/guests/$1"
  {
    if [ -d "$_vpf_guest_dir" ]; then
      find "$_vpf_guest_dir" -type f -exec cat {} +
    fi
    jq -c --arg n "$_vpf_name" '.VMs[] | select(.id == $n) | {hostname, shareDevDir, portForwards}' "$MANIFEST"
    printf '%s\n' "$vm_guest_credentials_fingerprint"
  } | vm_sha256_input
}

# vm_parse_utm_registered_names_from_list
#   Parse utmctl list table output on stdin; emit registered VM names (one per
#   line). WHY: registration lists every catalog entry regardless of Status.
vm_parse_utm_registered_names_from_list() {
  awk 'NR > 1 { print $3 }'
}

# vm_parse_utm_running_names_from_list
#   Parse utmctl list table output on stdin; emit names whose Status is not
#   stopped (starting, started, pausing, paused, resuming, stopping).
vm_parse_utm_running_names_from_list() {
  awk 'NR > 1 { sub(/ +$/, "", $2); if ($2 != "stopped") print $3 }'
}

# vm_parse_tart_registered_names_from_list
#   Parse tart list table output on stdin; emit catalog names (one per line).
#   WHY: the name column is existence in Tart's store, not running state.
vm_parse_tart_registered_names_from_list() {
  awk 'NR > 1 { print $2 }'
}

# vm_parse_tart_running_names_from_json
#   Parse tart list --format json on stdin; emit names with Running == true.
#   WHY: table layout changes across Tart releases; JSON .Running is stable.
vm_parse_tart_running_names_from_json() {
  require_command jq
  jq -r '.[] | select(.Running == true) | .Name'
}

# vm_get_utm_registered_names
#   Registered UTM VM names from the live hypervisor (not running state).
vm_get_utm_registered_names() {
  if [ ! -x "${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}" ]; then
    return 0
  fi
  "$UTMCTL" list 2>/dev/null | vm_parse_utm_registered_names_from_list
}

# vm_get_tart_registered_names
#   Registered Tart VM/image names from the live hypervisor (not running state).
vm_get_tart_registered_names() {
  command -v tart >/dev/null 2>&1 || return 0
  tart list 2>/dev/null | vm_parse_tart_registered_names_from_list
}

# vm_get_running_ids
#   Query hypervisors for currently running VM ids. Outputs one id per line;
#   empty output means nothing is running. WHY: state is read from the live
#   hypervisor rather than the manifest, so list/status reflect reality (e.g.
#   VMs started outside nucleus).
vm_get_running_ids() {
  case "$(uname -s)" in
  Darwin)
    if command -v tart >/dev/null 2>&1; then
      local _vgrn_tart_json _vgrn_tart_status
      _vgrn_tart_json="$(tart list --format json 2>&1)" || _vgrn_tart_status=$?
      if [ "${_vgrn_tart_status:-0}" -ne 0 ]; then
        error "tart list --format json failed; upgrade Tart to a release that supports --format json"
        return 1
      fi
      printf '%s\n' "$_vgrn_tart_json" | vm_parse_tart_running_names_from_json
    fi
    if [ -x "${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}" ]; then
      "$UTMCTL" list 2>/dev/null | vm_parse_utm_running_names_from_list
    fi
    ;;
  Linux)
    virsh list --name 2>/dev/null
    ;;
  MINGW* | MSYS* | CYGWIN*)
    return 0
    ;;
  esac
}

# wait_for_utm_registration NAME
#   Polls utmctl list until VM NAME appears or timeout is reached.
wait_for_utm_registration() {
  _wfur_name="$1"
  _wfur_attempt=1
  _wfur_max_attempts=15

  while [ "$_wfur_attempt" -le "$_wfur_max_attempts" ]; do
    if vm_get_utm_registered_names | grep -qxF "$_wfur_name"; then
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

  _wg_ssh_port="$(jq -r --arg t "$_wg_type" '[.VMs[] | select(.type == $t) | .portForwards[] | select(.guestPort == 22)][0].hostPort // empty' "$MANIFEST")"
  _wg_adb_port="$(jq -r --arg t "$_wg_type" '[.VMs[] | select(.type == $t) | .portForwards[] | select(.guestPort == 5555)][0].hostPort // empty' "$MANIFEST")"

  if [ "$_wg_type" = "NixOS" ]; then
    if command -v socat >/dev/null 2>&1; then
      while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
        echo '{"execute":"guest-ping"}' | socat - "PIPE:\\\\.\\pipe\\qga-$_wg_name" 2>/dev/null && return 0
        sleep 5
        _wg_elapsed=$((_wg_elapsed + 5))
      done
    fi
    while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$_wg_ssh_port" "$_wg_name@localhost" true 2>/dev/null && return 0
      sleep 5
      _wg_elapsed=$((_wg_elapsed + 5))
    done
    return 1
  elif [ "$_wg_type" = "Windows" ]; then
    if command -v socat >/dev/null 2>&1; then
      while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
        echo '{"execute":"guest-ping"}' | socat - "PIPE:\\\\.\\pipe\\qga-$_wg_name" 2>/dev/null && return 0
        sleep 5
        _wg_elapsed=$((_wg_elapsed + 5))
      done
    fi
    return 1
  elif [ "$_wg_type" = "Android" ]; then
    if command -v adb >/dev/null 2>&1; then
      while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
        if adb connect "localhost:$_wg_adb_port" 2>/dev/null | grep -q 'connected'; then
          return 0
        fi
        sleep 5
        _wg_elapsed=$((_wg_elapsed + 5))
      done
    fi
    _wg_elapsed=0
    while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$_wg_adb_port" "root@localhost" true 2>/dev/null && return 0
      sleep 5
      _wg_elapsed=$((_wg_elapsed + 5))
    done
    return 1
  elif [ "$_wg_type" = "macOS" ]; then
    while [ "$_wg_elapsed" -lt "$_wg_timeout" ]; do
      # check-suppress:suppression_doc: guest IP is not available until Tart softnet assigns one; empty is expected while waiting.
      _wg_guest_ip="$(tart ip "$_wg_name" 2>/dev/null || true)"
      if [ -n "$_wg_guest_ip" ]; then
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 -p 22 \
          "${vm_guest_username:?}@$_wg_guest_ip" true 2>/dev/null && return 0
      fi
      sleep 5
      _wg_elapsed=$((_wg_elapsed + 5))
    done
    return 1
  fi
  return 1
}

# vm_write_start_script DOC HOST_KIND
# Args:
#   $1 — JSON document for the VM: the self-describing descriptor when present
#        (vm_vm_json VM_ID), otherwise the manifest entry.  Fields read:
#        id/name/type/cpus/ram/portForwards (+ the Android group when present).
#   $2 — host runtime kind (darwin-utm|darwin-tart|nixos-libvirt|windows-qemu)
# Writes a host-side helper script to start the VM runtime from ~/virtual machines.
vm_write_start_script() {
  _wss_doc="$1"
  _wss_host_kind="$2"
  _wss_id="$(printf '%s' "$_wss_doc" | jq -r '.id')"
  _wss_display="$(printf '%s' "$_wss_doc" | jq -r '.name')"
  _wss_type="$(printf '%s' "$_wss_doc" | jq -r '.type')"
  mkdir -p "$VM_DIR/scripts"
  _wss_path_sh="$VM_DIR/scripts/start-${_wss_id}.sh"
  _wss_path_ps1="$VM_DIR/scripts/start-${_wss_id}.ps1"

  if [ "$dry_run" = true ]; then
    dry_run "write start helper scripts: $_wss_path_sh, $_wss_path_ps1"
    return 0
  fi

  _wss_tart_softnet_expose=""
  if [ "$_wss_host_kind" = "darwin-tart" ]; then
    _wss_tart_softnet_expose="$(printf '%s' "$_wss_doc" | jq -r '[.portForwards[] | "\(.hostPort):\(.guestPort)"] | join(",")')"
  fi

  if [ -f "$TEMPLATES_DIR/start-posix.sh" ]; then
    _wss_posix_sed=(
      -e "s|__VM_ID__|$_wss_id|g"
      -e "s|__VM_DISPLAY__|$_wss_display|g"
      -e "s|__VM_TYPE__|$_wss_type|g"
      -e "s|__HOST_KIND__|$_wss_host_kind|g"
      -e "s|__VM_DIR__|$VM_DIR|g"
    )
    if [ "$_wss_host_kind" = "darwin-tart" ]; then
      _wss_posix_sed+=(-e "s|__TART_SOFTNET_EXPOSE__|$_wss_tart_softnet_expose|g")
    else
      _wss_posix_sed+=(-e "s|__TART_SOFTNET_EXPOSE__||g")
    fi
    sed "${_wss_posix_sed[@]}" "$TEMPLATES_DIR/start-posix.sh" >"$_wss_path_sh"
  else
    warn "start-posix.sh template not found at $TEMPLATES_DIR/start-posix.sh"
    printf '#!/bin/sh\nset -eu\necho "VM start script for %s"\n' "$_wss_id" >"$_wss_path_sh"
  fi
  chmod 755 "$_wss_path_sh"

  case "$_wss_host_kind" in
  darwin-tart | darwin-utm | nixos-libvirt)
    if [ -f "$TEMPLATES_DIR/start-host.ps1" ]; then
      _wss_ps1_sed=(
        -e "s|__HOST_KIND__|$_wss_host_kind|g"
        -e "s|__VM_ID__|$_wss_id|g"
        -e "s|__VM_DISPLAY__|$_wss_display|g"
        -e "s|__VM_DIR__|$VM_DIR|g"
      )
      if [ "$_wss_host_kind" = "darwin-tart" ]; then
        _wss_ps1_sed+=(-e "s|__TART_SOFTNET_EXPOSE__|$_wss_tart_softnet_expose|g")
      else
        _wss_ps1_sed+=(-e "s|__TART_SOFTNET_EXPOSE__||g")
      fi
      sed "${_wss_ps1_sed[@]}" "$TEMPLATES_DIR/start-host.ps1" >"$_wss_path_ps1"
    else
      warn "start-host.ps1 template not found at $TEMPLATES_DIR/start-host.ps1"
      printf '# start script for %s\n' "$_wss_id" >"$_wss_path_ps1"
    fi
    ;;
  windows-qemu)
    if [ "$_wss_type" = "Android" ]; then
      # WHY: the Android QEMU start script is shared cross-platform content
      _wss_android_start="$REPO_ROOT/src/scripts/vms/start-android-vm.ps1"
      if [ ! -f "$_wss_android_start" ]; then
        error "shared Android VM start script not found: $_wss_android_start"
        return 1
      fi
      _wss_cpus="$(printf '%s' "$_wss_doc" | jq -r '.cpus')"
      _wss_ram_bytes="$(parse_size "$(printf '%s' "$_wss_doc" | jq -r '.ram')")"
      _wss_system_image="$(printf '%s' "$_wss_doc" | jq -r '.Android.systemImage')"
      _wss_userdata_image="$(printf '%s' "$_wss_doc" | jq -r '.Android.userdataImage')"
      _wss_gsi_image="$(printf '%s' "$_wss_doc" | jq -r '.Android.gsiImage')"
      _wss_hostfwds="$(printf '%s' "$_wss_doc" | jq -r '[.portForwards[] | "hostfwd=tcp::\(.hostPort)-:\(.guestPort)"] | join(",")')"
      sed -e "s|__ANDROID_CPU_COUNT__|$_wss_cpus|g" \
        -e "s|__ANDROID_RAM_BYTES__|${_wss_ram_bytes}B|g" \
        -e "s|__ANDROID_SYSTEM_IMAGE__|$_wss_system_image|g" \
        -e "s|__ANDROID_USERDATA_IMAGE__|$_wss_userdata_image|g" \
        -e "s|__ANDROID_GSI_IMAGE__|$_wss_gsi_image|g" \
        -e "s|__HOSTFWDS__|$_wss_hostfwds|g" \
        "$_wss_android_start" >"$_wss_path_ps1"
    else
      _wss_hostfwds="$(printf '%s' "$_wss_doc" | jq -r '[.portForwards[] | "hostfwd=tcp::\(.hostPort)-:\(.guestPort)"] | join(",")')"
      _wss_cpus="$(printf '%s' "$_wss_doc" | jq -r '.cpus')"
      _wss_ram_bytes="$(parse_size "$(printf '%s' "$_wss_doc" | jq -r '.ram')")"
      # WHY: the disk path is RELATIVE (data/<id>.qcow2, tree-root-relative)
      _wss_disk_path="data/${_wss_id}.qcow2"
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
          -e "s|__VM_ID__|$_wss_id|g" \
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
        printf '# start script for %s\n' "$_wss_id" >"$_wss_path_ps1"
      fi
      if [ -f "$TEMPLATES_DIR/start-windows-host.sh" ]; then
        sed -e "s|__QEMU_SYSTEM__|$_wss_qemu_system|g" \
          -e "s|__VM_ID__|$_wss_id|g" \
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

# vm_write_stop_script DOC HOST_KIND
# Args:
#   $1 — JSON document for the VM (see vm_write_start_script): the
#        self-describing descriptor when present, otherwise the manifest entry.
#   $2 — host runtime kind (darwin-utm|darwin-tart|nixos-libvirt|windows-qemu)
# Writes a host-side helper script to stop the VM runtime from ~/virtual machines.
vm_write_stop_script() {
  _wst_doc="$1"
  _wst_host_kind="$2"
  _wst_id="$(printf '%s' "$_wst_doc" | jq -r '.id')"
  _wst_display="$(printf '%s' "$_wst_doc" | jq -r '.name')"
  mkdir -p "$VM_DIR/scripts"
  _wst_path_sh="$VM_DIR/scripts/stop-${_wst_id}.sh"
  _wst_path_ps1="$VM_DIR/scripts/stop-${_wst_id}.ps1"

  if [ "$dry_run" = true ]; then
    dry_run "write stop helper scripts: $_wst_path_sh, $_wst_path_ps1"
    return 0
  fi

  case "$_wst_host_kind" in
  darwin-tart | darwin-utm | nixos-libvirt)
    if [ -f "$TEMPLATES_DIR/stop-posix.sh" ]; then
      sed -e "s|__HOST_KIND__|$_wst_host_kind|g" \
        -e "s|__VM_ID__|$_wst_id|g" \
        -e "s|__VM_DISPLAY__|$_wst_display|g" \
        "$TEMPLATES_DIR/stop-posix.sh" >"$_wst_path_sh"
    else
      warn "stop-posix.sh template not found at $TEMPLATES_DIR/stop-posix.sh"
      printf '#!/bin/sh\nset -eu\necho "stop script for %s"\n' "$_wst_id" >"$_wst_path_sh"
    fi
    ;;
  windows-qemu)
    # WHY: stop-posix.sh dispatches to tart/utmctl/virsh only.  QEMU guests
    :
    ;;
  *)
    error "unknown stop-script host kind: $_wst_host_kind"
    return 1
    ;;
  esac
  if [ -f "$_wst_path_sh" ]; then
    chmod 755 "$_wst_path_sh"
  fi

  case "$_wst_host_kind" in
  darwin-tart | darwin-utm | nixos-libvirt | windows-qemu)
    if [ -f "$TEMPLATES_DIR/stop-host.ps1" ]; then
      sed -e "s|__HOST_KIND__|$_wst_host_kind|g" \
        -e "s|__VM_ID__|$_wst_id|g" \
        "$TEMPLATES_DIR/stop-host.ps1" >"$_wst_path_ps1"
    else
      warn "stop-host.ps1 template not found at $TEMPLATES_DIR/stop-host.ps1"
      printf '# stop script for %s\n' "$_wst_id" >"$_wst_path_ps1"
    fi
    ;;
  *)
    error "unknown stop-script host kind: $_wst_host_kind"
    return 1
    ;;
  esac

  say "wrote stop helper scripts: $_wst_path_sh, $_wst_path_ps1"
}

# All-guests script pass

# vm_script_host_kind VM_TYPE
#   Prints the host runtime kind for the current host and guest type
#   (darwin-tart|darwin-utm|nixos-libvirt|windows-qemu).  Mirrors the
#   provisioner dispatch in scripts/vm.sh so helper scripts are written for
#   every host without a live hypervisor check.
vm_script_host_kind() {
  case "$(uname -s)" in
  Darwin)
    if [ "$1" = "macOS" ]; then
      printf 'darwin-tart\n'
    else
      printf 'darwin-utm\n'
    fi
    ;;
  Linux)
    printf 'nixos-libvirt\n'
    ;;
  MINGW* | MSYS* | CYGWIN*)
    printf 'windows-qemu\n'
    ;;
  *)
    error "unsupported host for VM helper scripts: $(uname -s)"
    return 1
    ;;
  esac
}

# vm_write_all_guest_scripts
#   Writes start/stop helper scripts (BOTH .sh and .ps1 variants) for EVERY
#   manifest guest — enabled or disabled, host-matched or not — so scripts/
#   serves all VMs without a live manifest (mirrors vm_write_descriptors).
#   Renders from vm_vm_json (descriptor-first, manifest fallback).
vm_write_all_guest_scripts() {
  local _wags_count _wags_i _wags_id _wags_type _wags_host_kind _wags_doc
  _wags_count="$(jq '.VMs | length' "$MANIFEST")"
  _wags_i=0
  while [ "$_wags_i" -lt "$_wags_count" ]; do
    _wags_id="$(jq -r ".VMs[$_wags_i].id" "$MANIFEST")"
    _wags_type="$(jq -r ".VMs[$_wags_i].type" "$MANIFEST")"
    _wags_host_kind="$(vm_script_host_kind "$_wags_type")" || return 1
    _wags_doc="$(vm_vm_json "$_wags_id")" || return 1
    vm_write_start_script "$_wags_doc" "$_wags_host_kind"
    vm_write_stop_script "$_wags_doc" "$_wags_host_kind"
    _wags_i=$((_wags_i + 1))
  done
  vm_write_pack_unpack_scripts
}

# vm_write_pack_unpack_scripts
#   Writes the global pack/unpack wrappers (BOTH variants) that delegate to
#   the nucleus-vm pack/unpack subcommands so pack operations work without
#   typing the subcommand (open question 6: thin delegation wrappers).
vm_write_pack_unpack_scripts() {
  mkdir -p "$VM_DIR/scripts"
  if [ "$dry_run" = true ]; then
    dry_run "write pack/unpack helper scripts: $VM_DIR/scripts/pack.*, unpack.*"
    return 0
  fi
  cat >"$VM_DIR/scripts/pack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec nucleus-vm pack "$@"
EOF
  chmod 755 "$VM_DIR/scripts/pack.sh"
  cat >"$VM_DIR/scripts/unpack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec nucleus-vm unpack "$@"
EOF
  chmod 755 "$VM_DIR/scripts/unpack.sh"
  cat >"$VM_DIR/scripts/pack.ps1" <<'EOF'
# Generated by nucleus-vm setup — pack.ps1. Delegates to nucleus-vm pack.
& nucleus-vm pack @args
exit $LASTEXITCODE
EOF
  cat >"$VM_DIR/scripts/unpack.ps1" <<'EOF'
# Generated by nucleus-vm setup — unpack.ps1. Delegates to nucleus-vm unpack.
& nucleus-vm unpack @args
exit $LASTEXITCODE
EOF
  say "wrote pack/unpack helper scripts: $VM_DIR/scripts"
}

# VM iteration helper

# vm_for_each CALLBACK [ARGS...]
#   Iterates VMs in MANIFEST, skipping disabled or host-mismatched entries.
#   For each enabled VM, calls CALLBACK with positional args:
#     vm_id vm_type vm_hosts vm_index [ARGS...]
vm_for_each() {
  local _callback="$1"
  shift
  local _count _i _vm_id _vm_type _vm_enabled _vm_hosts
  _count="$(jq '.VMs | length' "$MANIFEST")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _vm_id="$(jq -r ".VMs[$_i].id" "$MANIFEST")"
    _vm_type="$(jq -r ".VMs[$_i].type" "$MANIFEST")"
    _vm_enabled="$(jq -r ".VMs[$_i].enabled" "$MANIFEST")"

    case "$_vm_enabled" in
    true | false) ;;
    *)
      warn "VM '$_vm_id' has invalid enabled value '$_vm_enabled'; expected boolean true/false in manifest"
      _i=$((_i + 1))
      continue
      ;;
    esac

    if [ "$_vm_enabled" != "true" ]; then
      say "VM '$_vm_id' is disabled in manifest; skipping"
      _i=$((_i + 1))
      continue
    fi

    _vm_hosts="$(jq -c ".VMs[$_i].hosts" "$MANIFEST")"
    if ! should_include_host "$_vm_hosts"; then
      say "VM '$_vm_id' is not available on host '$NUCLEUS_HOST' (hosts: $_vm_hosts); skipping"
      _i=$((_i + 1))
      continue
    fi

    "$_callback" "$_vm_id" "$_vm_type" "$_vm_hosts" "$_i" "$@"
    _i=$((_i + 1))
  done
}

# vm_get_expected_vm_ids
#   Prints a newline-separated list of VM names from the manifest that are
#   enabled and match the current host.  Reuses the same filter logic as
#   vm_for_each but without the callback dispatch.
vm_get_expected_vm_ids() {
  if [ -z "$NUCLEUS_HOST" ]; then
    return 0
  fi
  jq -r --arg host "$NUCLEUS_HOST" '
    .VMs[] |
    select(.enabled == true) |
    select((.hosts // []) | contains([$host])) |
    .id
  ' "$MANIFEST"
}

# vm_get_manifest_vm_ids
#   Prints a newline-separated list of ALL VM names present in the manifest,
#   regardless of enabled state or host match.  Used by default GC so only
#   entries absent from VMs.json entirely are cleared; disabled entries are
#   preserved unless --gc-disabled is passed.
vm_get_manifest_vm_ids() {
  jq -r '.VMs[] | .id' "$MANIFEST"
}

# vm_descriptor_path VM_ID
#   Prints the path of the self-describing descriptor for a VM:
#   <VM_DIR>/<VM_ID>.vm.json.
vm_descriptor_path() {
  printf '%s/%s.vm.json\n' "$VM_DIR" "$1"
}

# vm_vm_json VM_ID
#   Prints the JSON document used to render a VM's artifacts: the
#   self-describing descriptor (<VM_DIR>/<VM_ID>.vm.json) when present, else
#   the manifest entry.  Descriptor-first so unpack (and setup on a
#   descriptor-carrying tree) renders from the packed/authoritative source;
#   the manifest fallback keeps a fresh tree working before descriptors are
#   written.  Mirror of the descriptor shape built by vm_write_descriptor.
vm_vm_json() {
  _vvj_desc="$(vm_descriptor_path "$1")"
  if [ -f "$_vvj_desc" ]; then
    cat "$_vvj_desc"
  else
    jq -c --arg n "$1" '.VMs[] | select(.id == $n)' "$MANIFEST"
  fi
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
  Android)
    printf 'aarch64\n'
    return 0
    ;;
  Windows)
    printf 'x86_64\n'
    return 0
    ;;
  esac
  _vda_host="$(uname -m)"
  case "$_vda_host" in
  arm64 | aarch64) printf 'aarch64\n' ;;
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
            {role: "system", path: ("src/" + $vm.type + "/" + $vm.Android.systemImage)}
          ]
          + (if ($vm.Android.gsiUrl != null) then
              [{role: "gsi", path: ("src/" + $vm.type + "/" + $vm.Android.gsiImage)}]
            else [] end)
          + [
            {role: "userdata", path: ("data/" + $vm.id + ".qcow2")}
          ]
        else
          [
            {role: "system", path: ("src/" + $vm.type + "/system image.qcow2")},
            {role: "data", path: ("data/" + $vm.id + ".qcow2")}
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

# resize_and_mark_image IMAGE_PATH MARKER_PATH FINGERPRINT [DISK_BYTES]
#   Writes FINGERPRINT to MARKER_PATH for drift detection.  When DISK_BYTES
#   is specified, also resizes IMAGE_PATH via qemu-img before marking
#   (qemu-img accepts bare byte counts).  Grow-only: the image is only
#   resized when its current virtual size is below DISK_BYTES; it is never
#   shrunk here.  WHY: a shrink can destroy data beyond the new end, so
#   shrinking is opt-in via 'nucleus-vm resize --allow-shrink' only.
resize_and_mark_image() {
  local _rmi_file="$1" _rmi_marker="$2" _rmi_fingerprint="$3" _rmi_disk_bytes="${4:-}"
  local _rmi_current_size

  if [ -n "$_rmi_disk_bytes" ]; then
    if command -v qemu-img >/dev/null 2>&1; then
      _rmi_current_size="$(qemu-img info --output=json "$_rmi_file" | jq -r '."virtual-size" // 0')"
      if [ "$_rmi_current_size" -lt "$_rmi_disk_bytes" ]; then
        if ! qemu-img resize "$_rmi_file" "$_rmi_disk_bytes" >/dev/null; then
          error "failed to resize $_rmi_file to $_rmi_disk_bytes bytes"
          return 1
        fi
      fi
    else
      error "qemu-img not found; cannot resize $_rmi_file to $_rmi_disk_bytes bytes"
      return 1
    fi
  fi
  printf '%s\n' "$_rmi_fingerprint" >"$_rmi_marker"
}

# vm_resize_vm NAME SIZE_BYTES ALLOW_SHRINK
#   Grows (or with ALLOW_SHRINK=true shrinks) the writable disk of manifest
#   VM NAME to SIZE_BYTES.  The writable disk is always data/<name>.qcow2 —
#   for Android that disk IS its userdata image, so resizing it resizes the
#   user's data disk.  Refuses to shrink without ALLOW_SHRINK (a shrink can
#   destroy data beyond the new end) and refuses while the VM is running.
#   Prints the old and new virtual sizes.
vm_resize_vm() {
  local _rvm_id="$1" _rvm_size_bytes="$2" _rvm_allow_shrink="$3"
  local _rvm_type _rvm_disk _rvm_old_size _rvm_running _rvm_qemu_args

  _rvm_type="$(jq -r --arg name "$_rvm_id" '.VMs[] | select(.id == $name) | .type // empty' "$MANIFEST")"
  if [ -z "$_rvm_type" ]; then
    error "VM '$_rvm_id' not found in manifest"
    return 1
  fi

  _rvm_disk="$VM_DIR/data/${_rvm_id}.qcow2"
  if [ ! -f "$_rvm_disk" ]; then
    error "writable disk not found for '$_rvm_id': $_rvm_disk (run 'nucleus-vm setup' first)"
    return 1
  fi

  _rvm_old_size="$(qemu-img info --output=json "$_rvm_disk" | jq -r '."virtual-size" // 0')"

  if [ "$_rvm_size_bytes" -le "$_rvm_old_size" ] && [ "$_rvm_allow_shrink" != "true" ]; then
    error "shrink requires --allow-shrink (current $_rvm_old_size bytes, target $_rvm_size_bytes bytes)"
    return 1
  fi

  _rvm_running="$(vm_get_running_ids)"
  if printf '%s\n' "$_rvm_running" | grep -qxF "$_rvm_id"; then
    error "VM '$_rvm_id' is running; stop it before resizing"
    return 1
  fi

  _rvm_qemu_args=()
  if [ "$_rvm_size_bytes" -lt "$_rvm_old_size" ]; then
    _rvm_qemu_args=(--shrink)
  fi
  if ! qemu-img resize "${_rvm_qemu_args[@]}" "$_rvm_disk" "$_rvm_size_bytes" >/dev/null; then
    error "failed to resize $_rvm_disk to $_rvm_size_bytes bytes"
    return 1
  fi

  say "resized '$_rvm_id' disk: $_rvm_old_size -> $_rvm_size_bytes bytes"
}

# data disk provisioning helper

# vm_ensure_data_disk NAME
#   Ensures the writable data disk for NAME under the managed layout:
#     src/<type>/system image.qcow2 — pristine type system image (read-only base)
#     data/<name>.qcow2             — writable data disk backing ../src/<type>/system image.qcow2
#   Everything (type, system image, manifest sizes, sidecar marker paths, and
#   the per-VM provision fingerprint) is derived from NAME alone.  Cases:
#   1. Data disk missing → create as an overlay on the type system image and
#      write provision markers.
#   2. Data disk exists and validates → KEEP it — never recreate, truncate, or
#      re-base an existing data disk.
#   3. Data disk invalid → warn and skip unless --force (default tells the
#      operator to run 'nucleus-vm reset <name>'; --force recreates with a
#      printed destructive warning).
#   4. Virtual size < manifest diskSize → auto-grow (never shrink).
#   Provision drift on a valid disk is reported by vm_provision_one (the
#   provision orchestrator), which owns the drift-to-inject hint.
vm_ensure_data_disk() {
  local _edd_name="$1"
  local _edd_type _edd_disk _edd_disk_valid _edd_backing_rel _edd_virtual_size
  local _edd_system_image _edd_min_size _edd_disk_bytes
  local _edd_provision_marker _edd_provision_fp

  mkdir -p "$VM_DIR/data"

  _edd_type="$(jq -r --arg n "$_edd_name" '.VMs[] | select(.id == $n) | .type' "$MANIFEST")"
  if [ -z "$_edd_type" ]; then
    error "VM '$_edd_name' not found in manifest; cannot provision data disk"
    return 1
  fi
  _edd_disk="$VM_DIR/data/${_edd_name}.qcow2"
  _edd_backing_rel="$(vm_system_image_rel_path "$_edd_type")"
  _edd_system_image="$(vm_src_path "$_edd_type" "$VM_SYSTEM_IMAGE")"
  _edd_min_size="$(parse_size "$(jq -r --arg n "$_edd_name" '.VMs[] | select(.id == $n) | .minImageSize' "$MANIFEST")")"
  _edd_disk_bytes="$(parse_size "$(jq -r --arg n "$_edd_name" '.VMs[] | select(.id == $n) | .diskSize' "$MANIFEST")")"
  _edd_provision_marker="$(vm_provision_marker_path "$_edd_disk")"
  # WHY: the provision fingerprint covers the per-VM guest identity
  # (src/vms/guests/<name>/), the provision-relevant manifest fields, and the
  # guest credential fingerprint; it is the drift key for in-place injection.
  _edd_provision_fp="$(vm_provision_fingerprint "$_edd_name")" || return 1

  _edd_disk_valid=false
  if [ -f "$_edd_disk" ] && validate_qcow2_image "$_edd_disk" "data disk for ${_edd_name}" "$_edd_min_size"; then
    _edd_disk_valid=true
  fi

  if [ "$_edd_disk_valid" = true ]; then
    # Data preservation: an existing valid data disk is never recreated,
    # truncated, or re-based during setup/sync.  Provision drift (a missing
    # or stale marker) is reported by vm_provision_one, the provision
    # orchestrator — never resolved here.
    say "data disk already exists: $_edd_disk"
  elif [ -f "$_edd_disk" ]; then
    warn "data disk is invalid for '$_edd_name': $_edd_disk"
    if [ "$force" != true ]; then
      warn "run 'nucleus-vm reset $_edd_name' to recreate it (or pass --force)"
      return 1
    fi
    warn "recreating data disk for '$_edd_name' (--force; this DESTROYS existing data)"
    if [ "$dry_run" = false ]; then
      rm -f "$_edd_disk" "$_edd_provision_marker"
    else
      dry_run "rm -f $_edd_disk $_edd_provision_marker"
      return 0
    fi
  fi

  if [ ! -f "$_edd_disk" ]; then
    if [ ! -f "$_edd_system_image" ]; then
      warn "system image not found: $_edd_system_image; cannot create data disk for '$_edd_name' (run 'nucleus-vm setup' first)"
      return 1
    fi
    if ! validate_qcow2_image "$_edd_system_image" "system image for ${_edd_name}" "$_edd_min_size"; then
      warn "system image is invalid for '$_edd_name': $_edd_system_image"
      return 1
    fi
    if [ "$dry_run" = false ]; then
      if ! qemu-img create -f qcow2 -b "$_edd_backing_rel" -F qcow2 "$_edd_disk" >/dev/null; then
        error "failed to create data disk: $_edd_disk"
        return 1
      fi
      printf '%s\n' "$_edd_provision_fp" >"$_edd_provision_marker"
      say "created data disk: $_edd_disk (backing $_edd_backing_rel)"
    else
      dry_run "qemu-img create -f qcow2 -b $_edd_backing_rel -F qcow2 $_edd_disk"
    fi
  fi

  if [ -n "$_edd_disk_bytes" ] && [ -f "$_edd_disk" ]; then
    _edd_virtual_size="$(qemu-img info --output=json "$_edd_disk" | jq -r '."virtual-size" // 0')"
    if [ -n "$_edd_virtual_size" ] && [ "$_edd_virtual_size" -lt "$_edd_disk_bytes" ]; then
      say "growing data disk for '$_edd_name' from $_edd_virtual_size to $_edd_disk_bytes bytes"
      if ! qemu-img resize "$_edd_disk" "$_edd_disk_bytes" >/dev/null; then
        error "failed to grow data disk: $_edd_disk"
        return 1
      fi
    fi
  fi

  return 0
}

# vm_provision_one NAME
#   Phase-2 per-VM provision orchestrator (shared by every runtime's setup
#   callback): ensures the writable data disk for NAME exists — create
#   overlay, keep existing — then reports provision drift (per-VM identity,
#   wiring, or credentials) for in-place re-injection while the VM is
#   stopped.  Host-specific wiring
#   (UTM bundle link, libvirt sync, start scripts) stays in the setup
#   callbacks; this function owns the shared disk+markers decision.  Drift
#   never triggers automatic recreation or injection at setup — the operator
#   runs 'nucleus-vm inject NAME'.
vm_provision_one() {
  local _vpo_name="$1" _vpo_type _vpo_disk _vpo_provision_marker _vpo_provision_fp _vpo_running

  _vpo_type="$(jq -r --arg n "$_vpo_name" '.VMs[] | select(.id == $n) | .type // empty' "$MANIFEST")"
  if [ -z "$_vpo_type" ]; then
    error "VM '$_vpo_name' not found in manifest; cannot provision data disk"
    return 1
  fi
  _vpo_disk="$VM_DIR/data/${_vpo_name}.qcow2"
  _vpo_provision_marker="$(vm_provision_marker_path "$_vpo_disk")"
  # WHY: the provision fingerprint covers per-VM identity, wiring, and
  # credentials; it is the drift key reported below.
  _vpo_provision_fp="$(vm_provision_fingerprint "$_vpo_name")" || return 1

  if ! vm_ensure_data_disk "$_vpo_name"; then
    return 1
  fi

  # Drift: the provision marker is missing or stale (a mismatch against
  # current inputs).  Never auto-inject or recreate here — report so the
  # operator can re-inject in place with the explicit command while the VM is
  # stopped.
  if ! vm_provision_marker_matches "$_vpo_provision_fp" "$_vpo_provision_marker"; then
    if [ "$_vpo_type" = "Android" ]; then
      # WHY: Android userdata is created empty and never injected; a stale
      # marker only means the inputs changed, so adopt it (marker adoption
      # only, no injection, no drift report).
      printf '%s\n' "$_vpo_provision_fp" >"$_vpo_provision_marker"
    else
      _vpo_running="$(vm_get_running_ids)"
      if printf '%s\n' "$_vpo_running" | grep -qxF "$_vpo_name"; then
        say "VM '$_vpo_name' is running; skipping in-place injection (applies on next setup)"
      else
        say "guest provision drift detected for '$_vpo_name'; run 'nucleus-vm inject $_vpo_name' to re-inject in place (data disk preserved)"
      fi
    fi
  fi
  return 0
}

# vm_link_android_userdata_to_utm_bundle NAME INDEX [BUNDLE_DATA_DIR]
#   Ensure Android.utm/Data/<userdataImage> is a hard link to data/<id>.qcow2
#   (G1a write-through).  Canonical data/ is the source of truth when present.
#   Never deletes userdata disks — only ln -f when canonical exists.
vm_link_android_userdata_to_utm_bundle() {
  _lautb_name="$1"
  _lautb_index="$2"
  _lautb_bundle_data_dir="${3:-}"

  _lautb_canonical="$VM_DIR/data/${_lautb_name}.qcow2"
  _lautb_userdata_image="$(jq -r ".VMs[$_lautb_index].Android.userdataImage" "$MANIFEST")"
  if [ -z "$_lautb_bundle_data_dir" ]; then
    _lautb_bundle_data_dir="$VM_DIR/${_lautb_name}.utm/Data"
  fi
  _lautb_bundle="$_lautb_bundle_data_dir/$_lautb_userdata_image"

  if [ ! -f "$_lautb_canonical" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    dry_run "link Android userdata into UTM bundle: $_lautb_bundle -> $_lautb_canonical"
    return 0
  fi

  mkdir -p "$_lautb_bundle_data_dir"
  if [ -f "$_lautb_bundle" ] && [ "$_lautb_bundle" -ef "$_lautb_canonical" ]; then
    say "Android userdata disk already linked: $_lautb_bundle"
    return 0
  fi

  ln -f "$_lautb_canonical" "$_lautb_bundle"
  say "linked Android userdata disk into UTM bundle: $_lautb_bundle"
  return 0
}

# vm_inject_guest NAME
#   Re-run in-place disk injection for one VM: applies the per-VM guest
#   identity (hostname, username, password, SSH key) into the existing data
#   disk without recreating it, then refreshes the provision marker so the
#   disk matches current inputs.  Dispatches by type:
#     NixOS   — qemu-nbd attach + nixos-enter applying src/vms/guests/<id>/guest.nix
#     Windows — libguestfs offline customization (virt-customize --in-place)
#     macOS   — tart clone of the type base VM (the clone is the per-VM layer)
#     Android — no injection; the userdata disk is created empty and needs no
#               identity (marker adoption only)
#   Refuses to run while the VM is running, and recreates the data disk first
#   when --force is set (destructive — prints a warning).  WHY: per-VM
#   identity is injected offline at setup time, never over the network, so a
#   fresh data disk gets its identity before first boot.
vm_inject_guest() {
  local _vig_name="$1"
  local _vig_type _vig_running _vig_disk _vig_provision_marker _vig_provision_fp

  _vig_type="$(jq -r --arg n "$_vig_name" '.VMs[] | select(.id == $n) | .type // empty' "$MANIFEST")"
  if [ -z "$_vig_type" ]; then
    error "VM '$_vig_name' not found in manifest; cannot inject"
    return 1
  fi

  if [ "$_vig_type" = "Android" ]; then
    say "no disk injection for Android VM '$_vig_name' (userdata disk is created empty; marker adoption only)"
    return 0
  fi

  # Running guard: never inject underneath a live guest.
  _vig_running="$(vm_get_running_ids)"
  if printf '%s\n' "$_vig_running" | grep -qxF "$_vig_name"; then
    say "VM '$_vig_name' is running; skipping in-place injection (stop it first, then re-run 'nucleus-vm inject $_vig_name')"
    return 0
  fi

  # WHY: per-VM identity uses the manifest hostname (the type build uses a
  # lowercase type-derived hostname instead); credentials and the SSH key are
  # already exported as NUCLEUS_VM_GUEST_* by vm_prepare_vm_command.
  export NUCLEUS_VM_GUEST_HOSTNAME
  NUCLEUS_VM_GUEST_HOSTNAME="$(jq -r --arg n "$_vig_name" '.VMs[] | select(.id == $n) | .hostname // empty' "$MANIFEST")"

  # NixOS/Windows inject into a qcow2 data disk; ensure one exists (recreate
  # first with --force, which is destructive and prints a warning).
  if [ "$_vig_type" = "NixOS" ] || [ "$_vig_type" = "Windows" ]; then
    _vig_disk="$VM_DIR/data/${_vig_name}.qcow2"
    _vig_provision_marker="$(vm_provision_marker_path "$_vig_disk")"
    # WHY: the provision fingerprint is the drift key refreshed after a
    # successful in-place injection.
    _vig_provision_fp="$(vm_provision_fingerprint "$_vig_name")" || return 1

    if [ "$force" = true ] && [ -f "$_vig_disk" ]; then
      warn "recreating data disk for '$_vig_name' (--force; this DESTROYS existing data)"
      if [ "$dry_run" = true ]; then
        dry_run "rm -f $_vig_disk $_vig_provision_marker"
      else
        rm -f "$_vig_disk" "$_vig_provision_marker"
      fi
    fi

    if [ ! -f "$_vig_disk" ]; then
      if [ "$force" != true ]; then
        error "data disk not found for '$_vig_name': $_vig_disk (run 'nucleus-vm setup $_vig_name' first, or pass --force to recreate it)"
        return 1
      fi
      if ! vm_ensure_data_disk "$_vig_name"; then
        return 1
      fi
    fi
  fi

  case "$_vig_type" in
  NixOS) vm_inject_nixos "$_vig_name" || return 1 ;;
  Windows) vm_inject_windows "$_vig_name" || return 1 ;;
  macOS) vm_inject_macos "$_vig_name" || return 1 ;;
  *)
    error "unsupported VM type for injection: $_vig_type"
    return 1
    ;;
  esac

  # WHY: after a successful in-place injection the disk now matches current
  # inputs, so refresh the provision markers to clear the drift that prompted
  # the re-inject.
  if [ "$_vig_type" = "NixOS" ] || [ "$_vig_type" = "Windows" ]; then
    if [ "$dry_run" = true ]; then
      dry_run "refresh provision marker for $_vig_name"
    else
      printf '%s\n' "$_vig_provision_fp" >"$_vig_provision_marker"
      say "refreshed provision marker for '$_vig_name'"
    fi
  fi
  return 0
}

# vm_inject_nixos NAME
#   Offline NixOS guest identity injection: attach data/<name>.qcow2 via
#   qemu-nbd, mount the btrfs root subvolume, stage the repo's src/ tree
#   inside the guest (preserving the relative imports of the guest config),
#   then apply src/vms/guests/<id>/guest.nix with nixos-enter.  The guest
#   config reads the NUCLEUS_VM_GUEST_* variables from the environment, which
#   nixos-enter passes through to the chroot.  Runs tools directly — qemu-nbd
#   and mount typically need root and fail visibly when unprivileged.
vm_inject_nixos() {
  local _vix_name="$1"
  local _vix_disk _vix_guest_nix _vix_mnt _vix_nbd _vix_part _vix_i

  if [ -z "${NUCLEUS_VM_GUEST_USERNAME:-}" ] || [ -z "${NUCLEUS_VM_GUEST_PASSWORD:-}" ]; then
    error "guest credentials not resolved; cannot inject NixOS identity for '$_vix_name'"
    return 1
  fi

  _vix_disk="$VM_DIR/data/${_vix_name}.qcow2"
  _vix_guest_nix="$VMS_DIR/guests/${_vix_name}/guest.nix"
  if [ ! -f "$_vix_guest_nix" ]; then
    error "guest config not found for NixOS VM '$_vix_name': $_vix_guest_nix"
    return 1
  fi
  if [ ! -f "$_vix_disk" ]; then
    error "data disk not found for '$_vix_name': $_vix_disk (run 'nucleus-vm setup $_vix_name' first, or pass --force to recreate it)"
    return 1
  fi

  require_command qemu-nbd
  require_command nixos-enter

  say "injecting NixOS guest identity into '$_vix_name' (qemu-nbd + nixos-enter)"
  if [ "$dry_run" = true ]; then
    dry_run "qemu-nbd attach $_vix_disk; nixos-enter apply $_vix_guest_nix"
    return 0
  fi

  # Pick the first free NBD device (no attached pid in sysfs).
  _vix_nbd=''
  for _vix_i in {0..15}; do
    if [ ! -e "/sys/class/block/nbd${_vix_i}/pid" ]; then
      _vix_nbd="/dev/nbd$_vix_i"
      break
    fi
  done
  if [ -z "$_vix_nbd" ]; then
    error "no free NBD device; cannot attach data disk for '$_vix_name'"
    return 1
  fi

  _vix_mnt="$(mktemp -d)"

  # WHY: NBD partition nodes appear asynchronously; both qcow-btrfs and
  # qcow-efi-btrfs layouts put the btrfs root on partition 2.
  _vix_part="${_vix_nbd}p2"

  _vix_cleanup() {
    umount "$_vix_mnt" >/dev/null 2>&1 || true # check-suppress:suppression_doc: best-effort unmount during cleanup; the disk may not be mounted on early failures
    qemu-nbd --disconnect "$_vix_nbd" >/dev/null 2>&1 || true # check-suppress:suppression_doc: best-effort disconnect during cleanup; the device may already be detached
    rm -rf "$_vix_mnt"
  }

  if ! qemu-nbd --format=qcow2 --connect="$_vix_nbd" "$_vix_disk"; then
    _vix_cleanup
    error "qemu-nbd attach failed for '$_vix_name': $_vix_disk"
    return 1
  fi

  for _vix_i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$_vix_part" ] && break
    sleep 1
  done
  if [ ! -e "$_vix_part" ]; then
    _vix_cleanup
    error "NBD partition node did not appear: $_vix_part"
    return 1
  fi

  if ! mount -o subvol=@ "$_vix_part" "$_vix_mnt"; then
    _vix_cleanup
    error "failed to mount $_vix_part (btrfs subvol=@) for '$_vix_name'"
    return 1
  fi

  # Stage the repo's src/ tree so the guest config's relative imports
  # (../../../src/...) resolve from inside the chroot, then apply the guest
  # config as /etc/nixos/configuration.nix with nixos-rebuild switch.
  if ! mkdir -p "$_vix_mnt/etc/nucleus-src" "$_vix_mnt/etc/nixos" ||
    ! cp -a "$REPO_ROOT/src" "$_vix_mnt/etc/nucleus-src/src"; then
    _vix_cleanup
    error "failed to stage repo tree inside guest '$_vix_name'"
    return 1
  fi
  cat >"$_vix_mnt/etc/nixos/configuration.nix" <<EOF
{ imports = [ /etc/nucleus-src/src/vms/guests/${_vix_name}/guest.nix ]; }
EOF

  say "applying guest config for '$_vix_name' via nixos-enter (this can take a while)"
  if ! nixos-enter --root "$_vix_mnt" --command "nixos-rebuild switch"; then
    _vix_cleanup
    error "nixos-enter apply failed for '$_vix_name'; see the error above"
    return 1
  fi

  _vix_cleanup
  say "injected NixOS guest identity into '$_vix_name'"
  return 0
}

# vm_inject_windows NAME
#   Offline Windows guest identity injection via libguestfs: virt-customize
#   --in-place edits data/<name>.qcow2 directly — sets the computer name,
#   creates the guest user with the SOPS password, and injects the SSH
#   public key.  WHY: Windows cannot be configured by writing files into the
#   disk blind; libguestfs handles the NTFS + registry work offline.
vm_inject_windows() {
  local _viw_name="$1"
  local _viw_disk _viw_username _viw_password _viw_hostname _viw_key_file _viw_args

  if [ -z "${NUCLEUS_VM_GUEST_USERNAME:-}" ] || [ -z "${NUCLEUS_VM_GUEST_PASSWORD:-}" ]; then
    error "guest credentials not resolved; cannot inject Windows identity for '$_viw_name'"
    return 1
  fi

  _viw_disk="$VM_DIR/data/${_viw_name}.qcow2"
  if [ ! -f "$_viw_disk" ]; then
    error "data disk not found for '$_viw_name': $_viw_disk (run 'nucleus-vm setup $_viw_name' first, or pass --force to recreate it)"
    return 1
  fi

  require_command virt-customize

  _viw_username="$NUCLEUS_VM_GUEST_USERNAME"
  _viw_password="$NUCLEUS_VM_GUEST_PASSWORD"
  _viw_hostname="${NUCLEUS_VM_GUEST_HOSTNAME:-$_viw_name}"

  _viw_key_file=''
  if [ -n "${NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY:-}" ]; then
    _viw_key_file="$(mktemp)"
    printf '%s\n' "$NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY" >"$_viw_key_file"
  fi

  say "injecting Windows guest identity into '$_viw_name' (libguestfs offline)"
  if [ "$dry_run" = true ]; then
    dry_run "virt-customize --in-place -a $_viw_disk --hostname $_viw_hostname (guest user, password, ssh key)"
    return 0
  fi

  _viw_args=(virt-customize --in-place -a "$_viw_disk" \
    --hostname "$_viw_hostname" \
    --password "user:$_viw_username:password:$_viw_password")
  if [ -n "$_viw_key_file" ]; then
    _viw_args+=(--ssh-inject "user:$_viw_username:file:$_viw_key_file")
  fi

  if ! "${_viw_args[@]}"; then
    rm -f "$_viw_key_file"
    error "virt-customize failed for '$_viw_name'; see the error above"
    return 1
  fi
  rm -f "$_viw_key_file"
  say "injected Windows guest identity into '$_viw_name'"
  return 0
}

# vm_inject_macos NAME
#   Per-VM macOS identity layer via tart clone: the clone of the type base
#   VM IS the per-VM writable layer (APFS copy-on-write), so no disk surgery
#   is needed — cloning from the identity-free type base is the injection.
vm_inject_macos() {
  local _vim_name="$1"
  local _vim_type

  require_command tart

  _vim_type="$(jq -r --arg n "$_vim_name" '.VMs[] | select(.id == $n) | .type' "$MANIFEST")"

  if vm_get_tart_registered_names | grep -qxF "$_vim_name"; then
    if [ "$force" != true ]; then
      say "macOS VM '$_vim_name' already cloned from type base '$_vim_type'; pass --force to re-clone (destructive)"
      return 0
    fi
    say "re-cloning macOS VM '$_vim_name' from type base '$_vim_type' (--force; this DESTROYS existing state)"
    if [ "$dry_run" = true ]; then
      dry_run "tart delete $_vim_name"
    elif ! tart delete "$_vim_name"; then
      error "tart delete failed for '$_vim_name'"
      return 1
    fi
  fi

  if ! vm_get_tart_registered_names | grep -qxF "$_vim_type"; then
    error "type base VM '$_vim_type' not found in Tart; run 'nucleus-vm build-system $_vim_type' first"
    return 1
  fi

  if [ "$dry_run" = true ]; then
    dry_run "tart clone $_vim_type $_vim_name"
    return 0
  fi

  if ! tart clone "$_vim_type" "$_vim_name"; then
    error "tart clone failed for '$_vim_name' from '$_vim_type'"
    return 1
  fi
  say "cloned macOS VM '$_vim_name' from type base '$_vim_type'"
  return 0
}

# --- Android guest configuration (adb / fastboot) ---

vm_android_adb_host_port() {
  jq -r --argjson i "$1" '.VMs[$i].portForwards[] | select(.guestPort == 5555) | .hostPort' "$MANIFEST"
}

vm_android_fastboot_host_port() {
  jq -r --argjson i "$1" '.VMs[$i].portForwards[] | select(.guestPort == 5554) | .hostPort' "$MANIFEST"
}

vm_android_adb_serial() {
  printf 'localhost:%s\n' "$(vm_android_adb_host_port "$1")"
}

vm_android_fastboot_serial() {
  printf 'tcp:localhost:%s\n' "$(vm_android_fastboot_host_port "$1")"
}

# vm_android_fastboot_probe SERIAL GETVAR_NAME
#   Return 0 when fastboot answers GETVAR_NAME within the probe timeout.
vm_android_fastboot_probe() {
  _afp_serial="$1"
  _afp_getvar="$2"
  _afp_out=''

  _afp_out="$(run_command_with_timeout 8 fastboot -s "$_afp_serial" getvar "$_afp_getvar" 2>&1)" || return 1
  printf '%s' "$_afp_out" | grep -q "^${_afp_getvar}:"
}

# vm_android_fastboot_list_state VM_INDEX
#   Return fastboot state for the manifest serial: fastboot or offline.
#   TCP fastboot (QEMU/jqssun) never appears in `fastboot devices`; probe with getvar.
vm_android_fastboot_list_state() {
  _afls_vm_index="$1"
  _afls_serial="$(vm_android_fastboot_serial "$_afls_vm_index")"

  if vm_android_fastboot_probe "$_afls_serial" is-userspace ||
    vm_android_fastboot_probe "$_afls_serial" version; then
    printf 'fastboot\n'
    return 0
  fi
  printf 'offline\n'
}

# vm_android_wait_tick TIMEOUT ELAPSED DEFAULT_POLL
#   Sleep min(poll, timeout - elapsed); echo new elapsed.
vm_android_wait_tick() {
  _awt_timeout="$1"
  _awt_elapsed="$2"
  _awt_default_poll="$3"
  _awt_poll="${NUCLEUS_VM_ANDROID_POLL_INTERVAL:-$_awt_default_poll}"
  _awt_remain=$((_awt_timeout - _awt_elapsed))
  if [ "$_awt_remain" -le 0 ]; then
    printf '%s' "$_awt_elapsed"
    return
  fi
  _awt_sleep="$_awt_remain"
  if [ "$_awt_poll" -lt "$_awt_sleep" ]; then
    _awt_sleep="$_awt_poll"
  fi
  sleep "$_awt_sleep"
  printf '%s' "$((_awt_elapsed + _awt_sleep))"
}

# vm_android_fastboot_wait VM_INDEX [TIMEOUT]
#   Wait until fastboot reports the manifest serial as fastboot.
vm_android_fastboot_wait() {
  _afw_vm_index="$1"
  _afw_timeout="${2:-180}"
  _afw_serial="$(vm_android_fastboot_serial "$_afw_vm_index")"
  _afw_elapsed=0
  _afw_last_hint=-30

  if [ "$(vm_android_fastboot_list_state "$_afw_vm_index")" = "fastboot" ]; then
    say "guest already in fastboot on $_afw_serial"
    return 0
  fi

  say "waiting for fastboot on $_afw_serial (timeout ${_afw_timeout}s)..."

  while [ "$_afw_elapsed" -lt "$_afw_timeout" ]; do
    if [ "$(vm_android_fastboot_list_state "$_afw_vm_index")" = "fastboot" ]; then
      return 0
    fi
    if [ "$_afw_elapsed" -ge "$((_afw_last_hint + 30))" ]; then
      say "manual step: in LineageOS Recovery, open Advanced → Enter fastboot"
      _afw_last_hint="$_afw_elapsed"
    fi
    _afw_elapsed="$(vm_android_wait_tick "$_afw_timeout" "$_afw_elapsed" 5)"
  done

  error "timed out waiting for fastboot on $_afw_serial; enter fastboot from recovery and retry"
  return 1
}

vm_android_adb_get_state() {
  _aas_serial="$(vm_android_adb_serial "$1")"
  adb -s "$_aas_serial" get-state 2>/dev/null || printf 'unknown\n'
}

# vm_android_adb_refresh VM_INDEX
#   Reset the TCP ADB session so adb devices reflects the current guest mode.
vm_android_adb_refresh() {
  _afr_vm_index="$1"
  _afr_serial="$(vm_android_adb_serial "$_afr_vm_index")"
  # check-suppress:suppression_doc: disconnect clears stale unauthorized/recovery entries on network ADB.
  adb disconnect "$_afr_serial" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: connect is idempotent; failure while the guest is still booting is expected.
  adb connect "$_afr_serial" >/dev/null 2>&1 || true
}

# vm_android_adb_list_state VM_INDEX
#   Return adb devices state for the manifest serial: device, unauthorized,
#   offline, recovery, sideload, or unknown.
vm_android_adb_list_state() {
  _als_vm_index="$1"
  _als_serial="$(vm_android_adb_serial "$_als_vm_index")"
  _als_devices_state="$(adb devices 2>/dev/null | awk -v serial="$_als_serial" '$1 == serial { print $2; exit }')"
  if [ -n "$_als_devices_state" ]; then
    printf '%s\n' "$_als_devices_state"
    return 0
  fi
  _als_get_state=''
  _als_get_state="$(adb -s "$_als_serial" get-state 2>/dev/null)" || _als_get_state=''
  if [ -n "$_als_get_state" ]; then
    printf '%s\n' "$_als_get_state"
    return 0
  fi
  printf 'offline\n'
}

# vm_android_adb_poll_state VM_INDEX
#   Refresh the TCP session and return the current adb state.
vm_android_adb_poll_state() {
  vm_android_adb_refresh "$1"
  vm_android_adb_list_state "$1"
}

# vm_android_adb_wait_authorized VM_INDEX [TIMEOUT]
#   Wait until the guest reports an authorized booted system (adb state device).
vm_android_adb_wait_authorized() {
  _awa_vm_index="$1"
  _awa_timeout="${2:-600}"
  _awa_serial="$(vm_android_adb_serial "$_awa_vm_index")"
  _awa_elapsed=0
  _awa_last_unauth_msg=-30

  say "waiting for authorized ADB on $_awa_serial (timeout ${_awa_timeout}s)..."

  while [ "$_awa_elapsed" -lt "$_awa_timeout" ]; do
    _awa_state="$(vm_android_adb_poll_state "$_awa_vm_index")"
    case "$_awa_state" in
    device) return 0 ;;
    unauthorized)
      if [ "$_awa_elapsed" -ge "$((_awa_last_unauth_msg + 30))" ]; then
        say "ADB unauthorized — boot LineageOS, enable USB debugging, and tap Allow on the device"
        _awa_last_unauth_msg="$_awa_elapsed"
      fi
      ;;
    recovery | sideload)
      if [ "$_awa_elapsed" -ge "$((_awa_last_unauth_msg + 30))" ]; then
        say "guest is in $_awa_state; boot LineageOS system for this step (Reboot system now from recovery)"
        _awa_last_unauth_msg="$_awa_elapsed"
      fi
      ;;
    esac
    _awa_elapsed="$(vm_android_wait_tick "$_awa_timeout" "$_awa_elapsed" 5)"
  done

  _awa_final="$(vm_android_adb_poll_state "$_awa_vm_index")"
  if [ "$_awa_final" = "unauthorized" ]; then
    error "timed out waiting for ADB authorization on $_awa_serial; boot LineageOS and tap Allow USB debugging"
  else
    error "timed out waiting for authorized ADB on $_awa_serial"
  fi
  return 1
}

# vm_android_guest_boot_completed VM_INDEX
#   True when the booted guest reports sys.boot_completed=1.
vm_android_guest_boot_completed() {
  _agbc_vm_index="$1"

  if [ "$(vm_android_adb_poll_state "$_agbc_vm_index")" != "device" ]; then
    return 1
  fi

  [ "$(vm_android_shell_getprop "$_agbc_vm_index" sys.boot_completed)" = "1" ]
}

# vm_android_adb_wait_boot_completed VM_INDEX [TIMEOUT]
#   Wait until adb is authorized and sys.boot_completed=1 (safe for pm/adb install).
vm_android_adb_wait_boot_completed() {
  _awbc_vm_index="$1"
  _awbc_timeout="${2:-600}"
  _awbc_serial="$(vm_android_adb_serial "$_awbc_vm_index")"
  _awbc_elapsed=0
  _awbc_last_hint=-30

  say "waiting for booted guest on $_awbc_serial (timeout ${_awbc_timeout}s)..."

  while [ "$_awbc_elapsed" -lt "$_awbc_timeout" ]; do
    _awbc_state="$(vm_android_adb_poll_state "$_awbc_vm_index")"
    case "$_awbc_state" in
    device)
      if vm_android_guest_boot_completed "$_awbc_vm_index"; then
        return 0
      fi
      if [ "$_awbc_elapsed" -ge "$((_awbc_last_hint + 30))" ]; then
        say "guest ADB is up but still booting (waiting for sys.boot_completed=1)..."
        _awbc_last_hint="$_awbc_elapsed"
      fi
      ;;
    unauthorized)
      if [ "$_awbc_elapsed" -ge "$((_awbc_last_hint + 30))" ]; then
        say "ADB unauthorized — boot LineageOS, enable USB debugging, and tap Allow on the device"
        _awbc_last_hint="$_awbc_elapsed"
      fi
      ;;
    recovery | sideload)
      if [ "$_awbc_elapsed" -ge "$((_awbc_last_hint + 30))" ]; then
        say "guest is in $_awbc_state; boot LineageOS system for this step (Reboot system now from recovery)"
        _awbc_last_hint="$_awbc_elapsed"
      fi
      ;;
    esac
    _awbc_elapsed="$(vm_android_wait_tick "$_awbc_timeout" "$_awbc_elapsed" 5)"
  done

  _awbc_final="$(vm_android_adb_poll_state "$_awbc_vm_index")"
  if [ "$_awbc_final" = "unauthorized" ]; then
    error "timed out waiting for booted guest on $_awbc_serial; tap Allow USB debugging"
  elif [ "$_awbc_final" = "device" ]; then
    error "timed out waiting for boot completion on $_awbc_serial (sys.boot_completed never became 1)"
  else
    error "timed out waiting for booted guest on $_awbc_serial (state: $_awbc_final)"
  fi
  return 1
}

# vm_android_adb_wait_sideload VM_INDEX [TIMEOUT]
#   Wait until ADB reports sideload (refreshes the TCP session each poll).
vm_android_adb_wait_sideload() {
  _aws_vm_index="$1"
  _aws_timeout="${2:-120}"
  _aws_serial="$(vm_android_adb_serial "$_aws_vm_index")"
  _aws_elapsed=0
  _aws_last_hint=-15

  say "waiting for sideload ADB on $_aws_serial (timeout ${_aws_timeout}s)..."

  while [ "$_aws_elapsed" -lt "$_aws_timeout" ]; do
    _aws_state="$(vm_android_adb_poll_state "$_aws_vm_index")"
    case "$_aws_state" in
    sideload) return 0 ;;
    recovery)
      if [ "$_aws_elapsed" -ge "$((_aws_last_hint + 15))" ]; then
        say "manual step: in recovery, select Apply update from ADB to enter sideload mode"
        _aws_last_hint="$_aws_elapsed"
      fi
      ;;
    unauthorized)
      if [ "$_aws_elapsed" -ge "$((_aws_last_hint + 15))" ]; then
        say "ADB unauthorized — enable ADB in recovery (Advanced → Enable ADB)"
        _aws_last_hint="$_aws_elapsed"
      fi
      ;;
    esac
    _aws_elapsed="$(vm_android_wait_tick "$_aws_timeout" "$_aws_elapsed" 2)"
  done

  _aws_final="$(vm_android_adb_poll_state "$_aws_vm_index")"
  error "timed out waiting for sideload ADB on $_aws_serial (state: $_aws_final)"
  return 1
}

# vm_android_adb_connect VM_INDEX [TIMEOUT]
#   Connect ADB and wait until the guest reports device, recovery, or sideload.
vm_android_adb_connect() {
  _aac_vm_index="$1"
  _aac_timeout="${2:-150}"
  _aac_serial="$(vm_android_adb_serial "$_aac_vm_index")"
  _aac_elapsed=0

  say "waiting for ADB on $_aac_serial (timeout ${_aac_timeout}s)..."

  while [ "$_aac_elapsed" -lt "$_aac_timeout" ]; do
    _aac_state="$(vm_android_adb_poll_state "$_aac_vm_index")"
    case "$_aac_state" in
    device | recovery | sideload) return 0 ;;
    esac
    _aac_elapsed="$(vm_android_wait_tick "$_aac_timeout" "$_aac_elapsed" 5)"
  done
  return 1
}

# vm_android_shell_getprop VM_INDEX NAME
#   Return a trimmed getprop value from the guest, or empty when unavailable.
vm_android_shell_getprop() {
  _asgp_vm_index="$1"
  _asgp_name="$2"
  _asgp_serial="$(vm_android_adb_serial "$_asgp_vm_index")"
  adb -s "$_asgp_serial" shell getprop "$_asgp_name" 2>/dev/null | tr -d '\r\n'
}

# vm_android_guest_shell_is_root VM_INDEX
#   True when adb shell runs as uid 0 (recovery native root shell).
vm_android_guest_shell_is_root() {
  _agsr_vm_index="$1"
  _agsr_serial="$(vm_android_adb_serial "$_agsr_vm_index")"

  adb -s "$_agsr_serial" shell 'id -u' 2>/dev/null | tr -d '\r' | grep -qx '0'
}

# vm_android_recovery_asset_suffix VM_INDEX
#   jqssun recovery image name suffix (arm64only or x86_64) for this guest.
vm_android_recovery_asset_suffix() {
  _aras_vm_index="$1"
  _aras_type="$(jq -r ".VMs[$_aras_vm_index].type" "$MANIFEST")"
  case "$(vm_derive_arch "$_aras_type")" in
  aarch64) printf 'arm64only\n' ;;
  *) printf 'x86_64\n' ;;
  esac
}

# vm_android_jqssun_release_tag_for_asset ASSET_NAME
#   Resolve the current jqssun release tag via the releases/latest/download redirect.
vm_android_jqssun_release_tag_for_asset() {
  _jrta_asset="$1"
  _jrta_location=''
  _jrta_tag=''

  if [ -z "$_jrta_asset" ]; then
    error "jqssun asset name is required"
    return 1
  fi

  _jrta_location="$(
    curl -fsI "https://github.com/jqssun/android-lineage-qemu/releases/latest/download/$_jrta_asset" |
      awk 'tolower($1) == "location:" { print $2; exit }' | tr -d '\r\n'
  )" || {
    error "failed to resolve jqssun release redirect for $_jrta_asset"
    return 1
  }

  if [ -z "$_jrta_location" ]; then
    error "failed to resolve jqssun release redirect for $_jrta_asset (no Location header)"
    return 1
  fi

  _jrta_tag="$(printf '%s' "$_jrta_location" | sed -n 's|.*/releases/download/\([^/]*\)/.*|\1|p')"
  if [ -z "$_jrta_tag" ]; then
    error "failed to parse jqssun release tag from redirect for $_jrta_asset"
    return 1
  fi

  printf '%s\n' "$_jrta_tag"
}

# vm_android_jqssun_asset_url TAG ASSET_SUBSTRING
#   Find a release asset download URL on GitHub without the REST API.
vm_android_jqssun_asset_url() {
  _jau_tag="$1"
  _jau_substring="$2"
  _jau_page=''
  _jau_path=''

  if [ -z "$_jau_tag" ] || [ -z "$_jau_substring" ]; then
    error "jqssun release tag and asset substring are required"
    return 1
  fi

  _jau_page="$(curl -fsSL "https://github.com/jqssun/android-lineage-qemu/releases/expanded_assets/$_jau_tag")" ||
    {
      error "failed to fetch jqssun release asset list for $_jau_tag"
      return 1
    }

  _jau_path="$(
    printf '%s' "$_jau_page" |
      grep -oE "href=\"/jqssun/android-lineage-qemu/releases/download/[^\"]*${_jau_substring}[^\"]*\"" |
      head -1 |
      sed -n 's/href="\([^"]*\)"/\1/p'
  )"
  if [ -z "$_jau_path" ]; then
    error "no jqssun asset matching '$_jau_substring' in release $_jau_tag"
    return 1
  fi

  printf 'https://github.com%s\n' "$_jau_path"
}

# vm_android_download_userdebug_recovery VM_INDEX
#   Download and cache the jqssun userdebug recovery image for sideloading GApps.
vm_android_download_userdebug_recovery() {
  _adur_vm_index="$1"
  _adur_suffix="$(vm_android_recovery_asset_suffix "$_adur_vm_index")"
  _adur_img="$(vm_src_path Android "$VM_ANDROID_RECOVERY_IMG")"
  _adur_tag_file="$(vm_src_path Android "$VM_ANDROID_RECOVERY_TAG")"
  _adur_asset_name="recovery_${_adur_suffix}-userdebug.img"
  _adur_dl_url="https://github.com/jqssun/android-lineage-qemu/releases/latest/download/$_adur_asset_name"
  _adur_tag=''

  _adur_tag="$(vm_android_jqssun_release_tag_for_asset "$_adur_asset_name")" || return 1

  if [ -f "$_adur_img" ]; then
    _adur_cached_tag=''
    if [ -f "$_adur_tag_file" ]; then
      _adur_cached_tag="$(jq -r '.tag_name // empty' "$_adur_tag_file")"
    fi
    if [ "$_adur_cached_tag" = "$_adur_tag" ]; then
      say "using cached userdebug recovery: $_adur_img"
      return 0
    fi
    say "jqssun release changed ($_adur_cached_tag → $_adur_tag); re-downloading userdebug recovery..."
    rm -f "$_adur_img"
  else
    say "downloading userdebug recovery ($_adur_asset_name)..."
  fi

  run_with_backoff "download userdebug recovery" \
    curl -fL -o "$_adur_img" "$_adur_dl_url" ||
    {
      error "failed to download userdebug recovery from $_adur_dl_url"
      return 1
    }

  jq -n --arg tag "$_adur_tag" '{tag_name: $tag}' >"$_adur_tag_file"
  say "userdebug recovery ready: $_adur_img"
  return 0
}

# vm_android_guest_has_userdebug_recovery VM_INDEX
#   True when recovery/sideload ADB reports a userdebug/eng build (LineageOS 23 sets ro.debuggable=0).
vm_android_guest_has_userdebug_recovery() {
  _aghur_vm_index="$1"
  _aghur_state="$(vm_android_adb_poll_state "$_aghur_vm_index")"
  _aghur_build_type=''
  _aghur_debuggable=''

  case "$_aghur_state" in
  recovery | sideload)
    _aghur_build_type="$(vm_android_shell_getprop "$_aghur_vm_index" ro.build.type)"
    _aghur_debuggable="$(vm_android_shell_getprop "$_aghur_vm_index" ro.debuggable)"
    case "$_aghur_build_type" in
    userdebug | eng) return 0 ;;
    esac
    [ "$_aghur_debuggable" = "1" ] && return 0
    ;;
  esac
  return 1
}

# vm_android_ensure_userdebug_recovery VM_INDEX
#   Flash the cached userdebug recovery via fastboot unless the guest already reports userdebug.
vm_android_ensure_userdebug_recovery() {
  _aeur_vm_index="$1"
  _aeur_img="$(vm_src_path Android "$VM_ANDROID_RECOVERY_IMG")"
  _aeur_fb_serial="$(vm_android_fastboot_serial "$_aeur_vm_index")"

  if [ ! -f "$_aeur_img" ]; then
    error "userdebug recovery image missing: $_aeur_img"
    return 1
  fi

  if [ "$(vm_android_fastboot_list_state "$_aeur_vm_index")" = "fastboot" ]; then
    say "guest already in fastboot on $_aeur_fb_serial"
  elif vm_android_guest_has_userdebug_recovery "$_aeur_vm_index"; then
    _aeur_build_type="$(vm_android_shell_getprop "$_aeur_vm_index" ro.build.type)"
    _aeur_debuggable="$(vm_android_shell_getprop "$_aeur_vm_index" ro.debuggable)"
    say "userdebug recovery is active on the guest (ro.build.type=${_aeur_build_type:-unknown}, ro.debuggable=${_aeur_debuggable:-0})"
    return 0
  else
    say "flashing userdebug recovery for MindTheGapps sideload..."
    say "manual step: in LineageOS Recovery, open Advanced → Enter fastboot (stock recovery cannot flash over ADB)"

    if ! vm_android_fastboot_wait "$_aeur_vm_index" 180; then
      return 1
    fi
  fi

  if ! fastboot -s "$_aeur_fb_serial" flash recovery "$_aeur_img"; then
    error "fastboot flash recovery failed on $_aeur_fb_serial; confirm Advanced → Enter fastboot is active on the VM"
    return 1
  fi

  # check-suppress:suppression_doc: fastboot reboot after flash is best-effort; guest may already be rebooting to recovery.
  fastboot -s "$_aeur_fb_serial" reboot 2>/dev/null || true
  say "userdebug recovery flashed; guest should reboot to recovery"
  say "manual step: in recovery, enable ADB (Advanced → Enable ADB) before sideload can continue"
  _aeur_settle="${NUCLEUS_VM_ANDROID_REBOOT_SETTLE_SECONDS:-10}"
  if [ "$_aeur_settle" -gt 0 ]; then
    sleep "$_aeur_settle"
  fi
}

# vm_android_adb_wait_recovery VM_INDEX [TIMEOUT]
#   Wait until ADB reports recovery or sideload (no booted-system RSA authorization).
vm_android_adb_wait_recovery() {
  _awr_vm_index="$1"
  _awr_timeout="${2:-300}"
  _awr_serial="$(vm_android_adb_serial "$_awr_vm_index")"
  _awr_elapsed=0
  _awr_last_hint=-30

  say "waiting for recovery ADB on $_awr_serial (timeout ${_awr_timeout}s)..."

  while [ "$_awr_elapsed" -lt "$_awr_timeout" ]; do
    _awr_state="$(vm_android_adb_poll_state "$_awr_vm_index")"
    case "$_awr_state" in
    recovery | sideload) return 0 ;;
    unauthorized)
      if [ "$_awr_elapsed" -ge "$((_awr_last_hint + 30))" ]; then
        say "ADB unauthorized — in userdebug recovery, enable ADB (Advanced → Enable ADB)"
        _awr_last_hint="$_awr_elapsed"
      fi
      ;;
    device)
      if [ "$_awr_elapsed" -ge "$((_awr_last_hint + 30))" ]; then
        say "guest is booted to system; boot LineageOS Recovery instead (power off → Reboot to recovery)"
        _awr_last_hint="$_awr_elapsed"
      fi
      ;;
    esac
    _awr_elapsed="$(vm_android_wait_tick "$_awr_timeout" "$_awr_elapsed" 5)"
  done

  _awr_final="$(vm_android_adb_poll_state "$_awr_vm_index")"
  if [ "$_awr_final" = "unauthorized" ]; then
    error "timed out waiting for recovery ADB on $_awr_serial; enable ADB in recovery (Advanced → Enable ADB)"
  else
    error "timed out waiting for recovery ADB on $_awr_serial (state: $_awr_final); boot LineageOS Recovery"
  fi
  return 1
}

# android (qemu/lineageos) image build

vm_build_android() {
  _bai_vm_id="$1"
  _bai_vm_index="$2"
  _bai_accept_gsi_license="$3"
  _bai_upgrade_android="$4"
  _bai_reset_userdata="$5"
  vm_ensure_type_src_dirs
  _bai_disk_bytes="$(parse_size "$(jq -r ".VMs[$_bai_vm_index].diskSize" "$MANIFEST")")"
  _bai_gsi_url="$(jq -r ".VMs[$_bai_vm_index].Android.gsiUrl" "$MANIFEST")"
  _bai_system_img="$(vm_src_path Android "$(jq -r ".VMs[$_bai_vm_index].Android.systemImage" "$MANIFEST")")"
  _bai_userdata_img="$VM_DIR/data/${_bai_vm_id}.qcow2"
  _bai_gsi_img="$(vm_src_path Android "$(jq -r ".VMs[$_bai_vm_index].Android.gsiImage" "$MANIFEST")")"
  _bai_system_replaced=false
  _bai_userdata_replaced=false

  _bai_share_dev_dir="$(jq -r ".VMs[$_bai_vm_index].shareDevDir // false" "$MANIFEST")"
  if [ "$_bai_share_dev_dir" = "true" ]; then
    error "shareDevDir is not supported for Android VM '$_bai_vm_id'; Android does not support host filesystem sharing via QEMU"
    exit 1
  fi

  if [ ! -f "$_bai_system_img" ] || [ "$_bai_upgrade_android" = "true" ]; then
    if [ "$_bai_upgrade_android" = "true" ] && [ -f "$_bai_system_img" ]; then
      say "upgrading Android system image for '$_bai_vm_id' (re-downloading)..."
      rm -f "$_bai_system_img"
    else
      say "downloading LineageOS base image for '$_bai_vm_id'..."
    fi
    _bai_suffix="$(vm_android_recovery_asset_suffix "$_bai_vm_index")"
    _bai_tag="$(vm_android_jqssun_release_tag_for_asset "boot_${_bai_suffix}.img")" ||
      {
        error "failed to resolve latest jqssun release tag"
        return 1
      }
    _bai_dl_url="$(vm_android_jqssun_asset_url "$_bai_tag" "UTM-VM-lineage-.*virtio_${_bai_suffix}.zip")" ||
      {
        error "no LineageOS UTM zip found in jqssun release $_bai_tag"
        return 1
      }
    _bai_lineage_zip="$(vm_src_path Android "$VM_ANDROID_LINEAGE_ZIP")"
    run_with_backoff "download LineageOS zip" \
      curl -fL -o "$_bai_lineage_zip" "$_bai_dl_url" ||
      {
        error "failed to download LineageOS zip"
        return 1
      }
    say "extracting LineageOS system image..."
    _bai_extract_dir="$(vm_src_path Android "$VM_ANDROID_LINEAGE_EXTRACT")"
    rm -rf "$_bai_extract_dir"
    mkdir -p "$_bai_extract_dir"
    run_cmd unzip -q "$_bai_lineage_zip" -d "$_bai_extract_dir"
    _bai_qcow2="$(find "$_bai_extract_dir" -type f -name '*.qcow2' -print | while IFS= read -r _f; do printf '%s %s\n' "$(wc -c <"$_f" | tr -d '[:space:]')" "$_f"; done | sort -rn | head -1 | cut -d' ' -f2-)"
    if [ -z "$_bai_qcow2" ]; then
      error "no qcow2 system image found inside extracted LineageOS bundle"
      return 1
    fi
    run_cmd cp "$_bai_qcow2" "$_bai_system_img"
    _bai_system_replaced=true
    rm -rf "$_bai_extract_dir" "$_bai_lineage_zip"
    validate_qcow2_image "$_bai_system_img" "Android system image for $_bai_vm_id" "$(parse_size "$(jq -r ".VMs[$_bai_vm_index].minImageSize" "$MANIFEST")")" || return 1
    say "system image ready: $_bai_system_img"
  else
    say "system image already exists: $_bai_system_img"
  fi

  mkdir -p "$VM_DIR/data"
  if [ ! -f "$_bai_userdata_img" ] || [ "$_bai_reset_userdata" = "true" ]; then
    if [ "$_bai_reset_userdata" = "true" ] && [ -f "$_bai_userdata_img" ]; then
      say "resetting Android userdata disk..."
      rm -f "$_bai_userdata_img"
    fi
    if [ ! -f "$_bai_userdata_img" ]; then
      say "creating userdata disk (${_bai_disk_bytes} bytes)..."
      run_cmd qemu-img create -f qcow2 "$_bai_userdata_img" "$_bai_disk_bytes"
      _bai_userdata_replaced=true
      validate_qcow2_image "$_bai_userdata_img" "Android userdata disk for $_bai_vm_id" "$(parse_size "$(jq -r ".VMs[$_bai_vm_index].minImageSize" "$MANIFEST")")" || return 1
      say "userdata disk ready: $_bai_userdata_img"
    fi
  else
    say "userdata disk already exists: $_bai_userdata_img"
  fi

  if [ -n "$_bai_gsi_url" ] && [ "$_bai_gsi_url" != "null" ]; then
    if [ "$_bai_accept_gsi_license" != "true" ]; then
      error "GSI license not accepted for '$_bai_vm_id'; see https://developer.android.com/license"
      exit 1
    fi
    say "GSI license: https://developer.android.com/license"
    if [ ! -f "$_bai_gsi_img" ]; then
      say "downloading GSI system image..."
      _bai_gsi_zip="$(vm_src_path Android "$VM_ANDROID_GSI_DOWNLOAD_ZIP")"
      run_with_backoff "download GSI zip" \
        curl -fL -o "$_bai_gsi_zip" "$_bai_gsi_url" ||
        {
          error "failed to download GSI zip from $_bai_gsi_url"
          return 1
        }
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
    say "no GSI URL set; skipping GSI download (Lineage-only)"
  fi

  # bundle; skipped in dry-run (no real mutations).  WHY: do_upgrade and
  if [ "$dry_run" = false ]; then
    if [ "$_bai_system_replaced" = true ] || [ "$_bai_userdata_replaced" = true ]; then
      _bai_bundle_dir="$VM_DIR/${_bai_vm_id}.utm/Data"
      if [ -d "$_bai_bundle_dir" ]; then
        if [ "$_bai_userdata_replaced" = true ]; then
          vm_link_android_userdata_to_utm_bundle "$_bai_vm_id" "$_bai_vm_index" "$_bai_bundle_dir" ||
            return 1
        fi
        if [ "$_bai_system_replaced" = true ]; then
          _bai_bundle_system="$_bai_bundle_dir/disk-main.qcow2"
          if [ -f "$_bai_bundle_system" ]; then
            cp "$_bai_system_img" "$_bai_bundle_system"
            say "refreshed Android system disk in UTM bundle: $_bai_bundle_system"
          fi
        fi
      fi
    fi
  fi

  say "Android image build complete for '$_bai_vm_id'"
}

# Image build callback for vm_for_each (Android only).  WHY: Android is the
# only type whose system/GSI images are downloaded per-VM (gsiUrl) instead of
# being built once per type; all other types are handled by vm_build_system.
vm_build_android_image() {
  local _vai_id="$1" _vai_type="$2" _vai_hosts="$3" _vai_index="$4"
  if [ "$_vai_type" != "Android" ]; then
    return 0
  fi

  # check-suppress:suppression_doc: best-effort -- a prerequisite-missing or build failure for one
  vm_build_android "$_vai_id" "$_vai_index" \
    "$accept_gsi_license" "$upgrade_android" "$reset_userdata" ||
    say "Android image build skipped for '$_vai_id' (prerequisite missing or build failed; see above)"
}

# vm_prune_and_write_all_guest_scripts
#   Removes stale scripts/ helpers then regenerates the full all-guests set.
vm_prune_and_write_all_guest_scripts() {
  for _pwgas_f in "$VM_DIR/scripts"/*.sh "$VM_DIR/scripts"/*.ps1; do
    [ -f "$_pwgas_f" ] || continue
    rm -f "$_pwgas_f"
  done
  vm_write_all_guest_scripts
}

# vm_validate_utm_plist_template NAME
#   Validates the Nix-rendered UTM plist template for NAME.  On success sets
#   _vupt_template to the template path and returns 0.
vm_validate_utm_plist_template() {
  local _vupt_name="$1"

  _vupt_template="${HOME}/.local/share/nucleus/vms/${_vupt_name}-config.plist"
  if [ ! -f "$_vupt_template" ]; then
    warn "UTM config template not found at $_vupt_template; apply the macOS config first"
    return 1
  fi
  if grep -qE 'virtio-ramfb-gl|<key>DirectorySharing</key>|<key>ReadOnlySharing</key>|<key>SharedDirectories</key>' "$_vupt_template"; then
    warn "stale UTM template detected at $_vupt_template; run home-manager switch (or nucleus apply) before vm sync"
    return 1
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
    if ! grep -Fq "$_required_utm_key" "$_vupt_template"; then
      _missing_utm_keys="$_missing_utm_keys ${_required_utm_key#<key>}"
    fi
  done
  if [ -n "$_missing_utm_keys" ]; then
    warn "stale or incomplete UTM template detected at $_vupt_template (missing key(s):$_missing_utm_keys); run home-manager switch (or nucleus apply) before vm sync"
    return 1
  fi
  return 0
}

# vm_apply_utm_plist_and_register NAME BUNDLE TEMPLATE_DRIFT_CONFIG
#   Copies the managed plist into an existing UTM bundle and ensures UTM has
#   the VM registered (open on first import; re-register on config drift).
vm_apply_utm_plist_and_register() {
  local _ap_name="$1" _ap_bundle="$2" _ap_template_drift="$3"
  local _ap_config_plist="$_ap_bundle/config.plist"

  if ! vm_validate_utm_plist_template "$_ap_name"; then
    return 1
  fi

  if [ "$dry_run" = false ]; then
    cp "$_vupt_template" "$_ap_config_plist"
    chmod +w "$_ap_config_plist"
    say "refreshed UTM bundle config: $_ap_bundle"
    if ! vm_get_utm_registered_names | grep -qxF "$_ap_name"; then
      say "opening UTM bundle in place: $_ap_bundle"
      if open "$_ap_bundle"; then
        if wait_for_utm_registration "$_ap_name"; then
          say "UTM VM opened and registered: $_ap_name"
        else
          warn "UTM did not register VM '$_ap_name' within timeout; open UTM and retry vm sync"
        fi
      else
        warn "opening $_ap_bundle failed; ensure UTM can access the managed VM directory and retry"
      fi
    elif [ "$_ap_template_drift" = true ]; then
      say "repairing stale UTM runtime registration for $_ap_name"
      if re_register_utm_bundle "$_ap_name" "$_ap_bundle"; then
        say "stale UTM registration repaired: $_ap_name"
      fi
    else
      say "UTM VM already registered: $_ap_name"
    fi
  else
    dry_run "refresh UTM bundle $_ap_bundle from $_vupt_template"
  fi
}

# vm_sync_utm — Config-only UTM refresh: plist copy + registration when the
#   bundle already exists.  Skips disk/image work (use vm_setup_utm for that).
vm_sync_utm() {
  local vm_id="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display bundle config_plist template_drift_config

  if [ "$vm_type" = "macOS" ]; then
    return
  fi

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")
  bundle="$VM_DIR/${vm_id}.utm"
  config_plist="$bundle/config.plist"
  template_drift_config=false

  if [ ! -d "$bundle" ]; then
    say "UTM bundle not found for '$vm_display'; run 'nucleus-vm setup' to create it"
    return
  fi

  say "syncing UTM VM '$vm_display'..."
  if [ -f "$config_plist" ] && vm_validate_utm_plist_template "$vm_id" &&
    ! cmp -s "$_vupt_template" "$config_plist"; then
    template_drift_config=true
    say "detected config drift in existing bundle; VM will be re-registered to refresh runtime state: $vm_id"
  elif [ ! -f "$config_plist" ]; then
    vm_validate_utm_plist_template "$vm_id" || return
  fi

  if [ "$vm_type" = "Android" ]; then
    vm_link_android_userdata_to_utm_bundle "$vm_id" "$vm_index" "$bundle/Data" ||
      return 1
  fi

  vm_apply_utm_plist_and_register "$vm_id" "$bundle" "$template_drift_config"
}

vm_sync_utm_vms() {
  if [ ! -d /Applications/UTM.app ]; then
    say "UTM not found at /Applications/UTM.app; skipping macOS VM sync"
    return
  fi

  vm_for_each vm_sync_utm
  say "macOS VM sync complete"
}

# vm_sync_libvirt — Config-only libvirt refresh: virsh define from the
#   Nix-installed domain XML.  Skips disk/overlay provisioning.
vm_sync_libvirt() {
  local vm_id="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local _xml_file

  _xml_file="/etc/nucleus/vms/${vm_id}-domain.xml"
  if [ ! -f "$_xml_file" ]; then
    warn "domain XML not found at $_xml_file; apply the NixOS config first"
    return
  fi

  if [ "$dry_run" = false ]; then
    if virsh define "$_xml_file"; then
      say "VM '$vm_id' defined/updated in libvirt"
    else
      warn "virsh define failed for '$vm_id'; check libvirtd status"
    fi
  else
    dry_run "virsh define $_xml_file"
  fi
}

vm_sync_libvirt_vms() {
  if ! command -v virsh >/dev/null 2>&1; then
    say "virsh not found in PATH; libvirtd may not be enabled yet"
    say "apply the NixOS configuration first so vms.nix activates libvirtd"
    return
  fi

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

  vm_for_each vm_sync_libvirt
  say "NixOS VM sync complete"
}

# vm_warn_running_vms_needing_restart
#   Warn when VMs are running so the user knows to restart for config changes.
vm_warn_running_vms_needing_restart() {
  local _wrvnr_running _wrvnr_name

  _wrvnr_running="$(vm_get_running_ids)" || return 0
  [ -n "$_wrvnr_running" ] || return 0
  printf '%s\n' "$_wrvnr_running" | while IFS= read -r _wrvnr_name; do
    [ -z "$_wrvnr_name" ] && continue
    warn "VM '$_wrvnr_name' is running; stop and restart it for config changes (e.g. port forwards) to take effect"
  done
}

# vm_sync_config_phase — Non-destructive config refresh shared by nucleus-vm
#   sync and the first phase of nucleus-vm setup.
vm_sync_config_phase() {
  vm_write_descriptors
  vm_prune_and_write_all_guest_scripts

  if [ "$(uname -s)" = "Darwin" ]; then
    ensure_tart_vm_dir
  fi

  case "$(uname -s)" in
  Darwin)
    vm_sync_utm_vms
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      vm_sync_libvirt_vms
    fi
    ;;
  MINGW* | MSYS* | CYGWIN*)
    say "Windows VM sync: start/stop scripts refreshed (no hypervisor domain to define)"
    ;;
  esac

  vm_warn_running_vms_needing_restart
}

# Tart VM setup callback for vm_for_each

vm_setup_tart() {
  local vm_id="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"

  if [ "$vm_type" != "macOS" ]; then
    return
  fi

  if ! vm_get_tart_registered_names | grep -qxF "$vm_id"; then
    warn "tart VM '$vm_id' not found; Packer build may have failed or was skipped"
    return
  fi

  if [ "$dry_run" = false ]; then
    say "tart VM ready: $vm_id (start with: tart run $vm_id)"
  else
    dry_run "verify tart VM registration: $vm_id"
  fi
}

# UTM VM setup callback for vm_for_each

vm_setup_utm() {
  local vm_id="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display bundle data_dir disk_file
  local config_plist bundle_exists template_drift_config
  local template_drift_config _prebuilt _prebuilt_valid _prebuilt_min_size
  local _android_system _android_userdata _android_gsi _userdata_file _gsi_file

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")

  if [ "$vm_type" = "macOS" ]; then
    say "macOS guest '$vm_id' stays on Tart runtime; skipping UTM bundle provisioning for this VM"
    return
  fi

  bundle="$VM_DIR/${vm_id}.utm"
  data_dir="$bundle/Data"
  disk_file="$data_dir/disk-main.qcow2"
  config_plist="$bundle/config.plist"
  bundle_exists=false
  template_drift_config=false

  say "configuring UTM VM '$vm_display'..."

  if [ -d "$bundle" ]; then
    bundle_exists=true
    say "UTM bundle already exists: $bundle; refreshing config.plist"
  fi

  if ! vm_validate_utm_plist_template "$vm_id"; then
    return
  fi
  if [ "$bundle_exists" = true ] && [ -f "$config_plist" ] && ! cmp -s "$_vupt_template" "$config_plist"; then
    template_drift_config=true
    say "detected config drift in existing bundle; VM will be re-registered to refresh runtime state: $vm_id"
  fi
  if [ "$vm_type" = "Android" ]; then
    _android_system="$(vm_src_path Android "$(jq -r ".VMs[$vm_index].Android.systemImage" "$MANIFEST")")"
    _android_userdata="$VM_DIR/data/${vm_id}.qcow2"
    _android_gsi="$(vm_src_path Android "$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")")"
  fi

  if [ "$vm_type" = "Android" ]; then
    _prebuilt="$_android_system"
  else
    _prebuilt="$(vm_src_path "$vm_type" "$VM_SYSTEM_IMAGE")"
  fi
  _prebuilt_valid=false
  if [ ! -f "$disk_file" ] && [ ! -f "$_prebuilt" ]; then
    _build_tmp="$(vm_src_path "$vm_type" "$VM_PACKER_BUILD_DIR")"
    if [ -d "$_build_tmp" ]; then
      warn "image not ready for '$vm_id'; build appears in progress at $_build_tmp"
    else
      warn "image not found: $_prebuilt; build failed or type not supported"
    fi
    return
  fi

  _prebuilt_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
  if [ -f "$_prebuilt" ]; then
    if validate_qcow2_image "$_prebuilt" "pre-built image for ${vm_id}" "$_prebuilt_min_size"; then
      _prebuilt_valid=true
    else
      warn "pre-built image is invalid for '$vm_id': $_prebuilt"
      return
    fi
  fi

  if [ "$dry_run" = false ]; then
    mkdir -p "$data_dir"
    if [ "$vm_type" = "Android" ]; then
      if [ ! -f "$_android_userdata" ]; then
        warn "Android userdata image not found: $_android_userdata; run vm-build first"
        return
      fi
      _replace_runtime=false
      if [ -f "$disk_file" ] && ! validate_qcow2_image "$disk_file" "existing UTM runtime disk for ${vm_id}" "$_prebuilt_min_size"; then
        warn "existing Android runtime disk is invalid for '$vm_id'; replacing from pre-built image"
        rm -f "$disk_file"
        _replace_runtime=true
      fi
      if [ ! -f "$disk_file" ]; then
        if [ "$_prebuilt_valid" != true ]; then
          warn "cannot create the $vm_id Android runtime disk because no valid system image is available: $_android_system"
          return
        fi
        cp "$_android_system" "$disk_file"
        say "copied Android system image: $disk_file"
      elif [ "$_replace_runtime" = true ]; then
        warn "replacement was requested for '$vm_id' but the Android runtime disk still exists; leaving it untouched"
      else
        say "preserving existing Android system disk: $disk_file"
      fi
      if ! vm_link_android_userdata_to_utm_bundle "$vm_id" "$vm_index" "$data_dir"; then
        return 1
      fi
      _gsi_url="$(jq -r ".VMs[$vm_index].Android.gsiUrl" "$MANIFEST")"
      _gsi_file="$data_dir/$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")"
      if [ -n "$_gsi_url" ] && [ "$_gsi_url" != "null" ]; then
        if [ -f "$_android_gsi" ]; then
          cp "$_android_gsi" "$_gsi_file"
          say "copied Android GSI image: $_gsi_file"
        elif [ -f "$_gsi_file" ]; then
          warn "Android GSI image removed from images dir; removing stale bundle copy: $_gsi_file"
          rm -f "$_gsi_file"
        fi
      elif [ -f "$_gsi_file" ]; then
        warn "Android gsiUrl is null; removing stale GSI from bundle: $_gsi_file"
        rm -f "$_gsi_file"
      fi
    else
      if ! vm_provision_one "$vm_id"; then
        return
      fi
      ln -f "$VM_DIR/data/${vm_id}.qcow2" "$disk_file"
      say "linked data disk into UTM bundle: $disk_file"
    fi
    if [ "$bundle_exists" != true ]; then
      say "UTM bundle created: $bundle"
    fi
    vm_apply_utm_plist_and_register "$vm_id" "$bundle" "$template_drift_config"
  else
    dry_run "provision UTM bundle disks for $bundle"
    vm_apply_utm_plist_and_register "$vm_id" "$bundle" "$template_drift_config"
  fi
}

# Libvirt VM setup callback for vm_for_each

vm_setup_libvirt() {
  local vm_id="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display disk_path _prebuilt
  local _prebuilt_min_size
  local _android_system _android_userdata _android_gsi

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")

  disk_path="$VM_DIR/data/${vm_id}.qcow2"

  say "configuring libvirt VM '$vm_display' (hosts: $vm_hosts)..."

  if [ "$vm_type" = "Android" ]; then
    _android_system="$(vm_src_path Android "$(jq -r ".VMs[$vm_index].Android.systemImage" "$MANIFEST")")"
    _android_userdata="$VM_DIR/data/${vm_id}.qcow2"
    _android_gsi="$(vm_src_path Android "$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")")"
    if [ ! -f "$_android_system" ] || [ ! -f "$_android_userdata" ]; then
      warn "Android images not found: $_android_system and $_android_userdata; skipping '$vm_id'"
      return
    fi
    _android_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
    if ! validate_qcow2_image "$_android_system" "Android system image for ${vm_id}" "$_android_min_size" ||
      ! validate_qcow2_image "$_android_userdata" "Android userdata disk for ${vm_id}" "$_android_min_size"; then
      warn "Android images are invalid for '$vm_id'"
      return
    fi
  else
    _prebuilt="$(vm_src_path "$vm_type" "$VM_SYSTEM_IMAGE")"
    _prebuilt_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
    if [ ! -f "$_prebuilt" ]; then
      warn "image not found: $_prebuilt; skipping '$vm_id'"
      return
    fi
    if ! validate_qcow2_image "$_prebuilt" "pre-built image for ${vm_id}" "$_prebuilt_min_size"; then
      warn "pre-built image is invalid for '$vm_id': $_prebuilt"
      return
    fi
  fi

  if [ "$dry_run" = false ]; then
    mkdir -p "$VM_DIR"
    if [ "$vm_type" = "Android" ]; then
      say "Android images referenced directly by domain XML: $_android_system, $_android_userdata"
    else
      if ! vm_provision_one "$vm_id"; then
        return
      fi
      say "data disk ready: $disk_path"
    fi
  else
    if [ "$vm_type" = "Android" ]; then
      dry_run "use Android images in domain XML: $_android_system, $_android_userdata"
    else
      dry_run "ensure data disk: $disk_path (overlay on $(vm_src_path "$vm_type" "$VM_SYSTEM_IMAGE"))"
    fi
  fi

  vm_sync_libvirt "$vm_id" "$vm_type" "$vm_hosts" "$vm_index"
}

# Phase 1 — Build images (if absent)

# vm_build_nixos TYPE DISK_BYTES
#   Builds the NixOS guest type system image via nixos-generators (pinned as a
#   flake input in src/flake.nix).  The image is identity-free and shared by
#   every VM of the type; per-VM identity is injected onto the data disk at
#   provision time.  On macOS this requires an aarch64-linux builder;
#   enable nix.linux-builder.enable in the macOS host config so the Nix daemon
#   delegates Linux derivations to the Virtualization.framework-backed builder
#   VM created by nix-darwin.  Most derivations are fetched from the binary
#   cache; hostname-specific ones (e.g. etc-hostname) are configuration-specific
#   and cannot be cached.
vm_build_nixos() {
  _vm_type="$1"
  _disk_bytes="$2"

  case "$(uname -m)" in
  aarch64 | arm64)
    _nixos_system='aarch64-linux'
    _nixos_format_path="$VMS_DIR/NixOS/formats/qcow-efi-btrfs.nix"
    ;;
  *)
    _nixos_system='x86_64-linux'
    _nixos_format_path="$VMS_DIR/NixOS/formats/qcow-btrfs.nix"
    ;;
  esac
  vm_ensure_type_src_dirs
  _out="$(vm_src_path "$_vm_type" "$VM_SYSTEM_IMAGE")"
  _marker="$(vm_type_config_marker_path "$_vm_type")"
  _min_size="$(parse_size "$(jq -r --arg t "$_vm_type" '[.VMs[] | select(.type == $t) | .minImageSize][0] // empty' "$MANIFEST")")"

  # WHY: the type system image is identity-free (nixos-generators), so the
  # type marker tracks config inputs only; per-VM identity (credentials)
  # drift surfaces via each data disk's provision marker instead.
  _type_fp="$(vm_type_config_fingerprint "$_vm_type")" || return 1

  if [ -f "$_out" ]; then
    if validate_qcow2_image "$_out" "existing NixOS image" "$_min_size"; then
      if vm_type_config_marker_matches "$_type_fp" "$_marker"; then
        say "NixOS image already built for the current guest config (owner=$vm_secret_owner, username=$vm_guest_username): $_out"
        return 0
      fi
      say "NixOS image guest config drift detected; rebuilding image: $_out"
    else
      warn "existing NixOS image is invalid; rebuilding from scratch: $_out"
    fi
    if [ "$dry_run" = false ]; then
      rm -f "$_out" "$_marker"
    else
      dry_run "rm -f $_out $_marker"
      return 0
    fi
  fi

  _guest_nix="$VMS_DIR/NixOS/base-guest.nix"
  if [ ! -f "$_guest_nix" ]; then
    error "nixos guest base config not found: $_guest_nix"
    return 1
  fi

  say "building NixOS image (system=$_nixos_system, format=$(basename "$_nixos_format_path" .nix))..."

  if [ "$dry_run" = true ]; then
    dry_run "nix run $REPO_ROOT/src#nixos-generators -- --format-path $_nixos_format_path --system $_nixos_system --configuration $_guest_nix -o <tmpdir>"
    return 0
  fi

  _tmpdir="$(mktemp -d)"
  _out_link="$_tmpdir/result"
  nix run "$REPO_ROOT/src#nixos-generators" -- \
    --format-path "$_nixos_format_path" \
    --system "$_nixos_system" \
    --configuration "$_guest_nix" \
    -o "$_out_link"

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
  copy_with_reflink "$_img" "$_out"
  chmod u+w "$_out"

  # WHY: nixos-generators defaults to a small virtual disk (~4 GiB) for qcow
  if ! resize_and_mark_image "$_out" "$_marker" "$_type_fp" "$_disk_bytes"; then
    rm -rf "$_tmpdir"
    return 1
  fi

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

  case "$(printf '%s' "$_mido_edition" | tr '[:upper:]' '[:lower:]')" in
  *enterprise*eval*) _mido_media='win11x64-enterprise-eval' ;;
  *) _mido_media='win11x64' ;;
  esac

  say "downloading Windows 11 ISO via Mido (media=$_mido_media)..."

  _mido_patch_file="${NUCLEUS_MIDO_PATCH_FILE:-$REPO_ROOT/src/vms/Windows/patches/mido-iso-link.patch}"
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
    # WHY: mido.sh checks if its parent directory is in PATH; if so it stays
    PATH="${PATH}:${_mido_tmp}:${_mido_dir}" sh "$_mido_exec_script" "$_mido_media"
  ) || _mido_status=$?

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

# vm_build_windows TYPE DISK_BYTES EDITION
#   Builds the Windows 11 guest type system image using Packer and the
#   Autounattend.xml answer file at src/vms/Windows/Autounattend.xml.
#   The image is identity-free and shared by every VM of the type; per-VM
#   identity is injected onto the data disk at provision time.
vm_build_windows() {
  _vm_type="$1"
  _disk_bytes="$2"
  _edition="$3"
  vm_ensure_type_src_dirs
  _out="$(vm_src_path "$_vm_type" "$VM_SYSTEM_IMAGE")"
  _marker="$(vm_type_config_marker_path "$_vm_type")"
  # WHY: the Windows type build bakes guest identity (Autounattend.xml
  # tokens, packer vars), so the type marker tracks config and credentials.
  _type_fp="$(vm_type_image_fingerprint "$_vm_type")" || return 1
  _min_size="$(parse_size "$(jq -r --arg t "$_vm_type" '[.VMs[] | select(.type == $t) | .minImageSize][0] // empty' "$MANIFEST")")"
  _hostfwd="$(jq -r --arg t "$_vm_type" '[.VMs[] | select(.type == $t)][0].portForwards | map("hostfwd=tcp::\(.hostPort)-:\(.guestPort)") | join(",")' "$MANIFEST")"
  _guest_hostname="$(printf '%s' "$_vm_type" | tr '[:upper:]' '[:lower:]')"

  if [ -f "$_out" ]; then
    if validate_qcow2_image "$_out" "existing Windows image" "$_min_size"; then
      if vm_type_config_marker_matches "$_type_fp" "$_marker"; then
        say "Windows image already built for the current guest config and credentials (owner=$vm_secret_owner, username=$vm_guest_username): $_out"
        return 0
      fi
      say "Windows image guest config/credential drift detected; rebuilding image: $_out"
    fi
    warn "existing Windows image is invalid; rebuilding from scratch: $_out"
    rm -f "$_out" "$_marker"
  fi

  _iso="$windows_iso"
  if [ -z "$_iso" ]; then
    say "Windows ISO fallback order: cached installer -> Windows.isoUrl -> downloader ($windows_iso_source mode)"
  fi

  if [ -z "$_iso" ]; then
    _cached_iso="$(vm_src_path "$_vm_type" "$VM_WINDOWS_INSTALLER_ISO")"
    if [ -f "$_cached_iso" ]; then
      say "using cached Windows installer: $_cached_iso"
      _iso="$_cached_iso"
    fi
  fi

  if [ -z "$_iso" ] && [ "$windows_iso_source" != "mido" ]; then
    _iso_url="$(jq -r --arg t "$_vm_type" '[.VMs[] | select(.type == $t)][0] | .Windows.isoUrl // empty' "$MANIFEST")"
    if [ -n "$_iso_url" ]; then
      _cached_iso="$(vm_src_path "$_vm_type" "$VM_WINDOWS_INSTALLER_ISO")"
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

  if [ -z "$_iso" ]; then
    _cached_iso="$(vm_src_path "$_vm_type" "$VM_WINDOWS_INSTALLER_ISO")"
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
        MINGW* | MSYS* | CYGWIN* | Windows_NT)
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
    error "alternatively add 'Windows.isoUrl': '<url>' to the VMs.json Windows entry"
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

  _packer_dir="$VMS_DIR/Windows"
  _tmp_out="$(vm_src_path "$_vm_type" "$VM_PACKER_BUILD_DIR")"
  _ssh_timeout='3h'
  if [ "$accelerator" = 'tcg' ]; then
    # WHY: x86_64 Windows setup under software emulation can take much longer
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
    "/Applications/UTM.app/Contents/Resources/qemu"; do
    [ -n "$_efi_dir" ] || continue
    if [ -z "$_efi_code" ] && [ -f "$_efi_dir/edk2-x86_64-code.fd" ]; then
      _efi_code="$_efi_dir/edk2-x86_64-code.fd"
    fi
    if [ -z "$_efi_vars" ] && [ -f "$_efi_dir/edk2-i386-vars.fd" ]; then
      _efi_vars_size="$(wc -c <"$_efi_dir/edk2-i386-vars.fd" | tr -d '[:space:]')"
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
      _pv="$_pv -var autounattend_path=$VMS_DIR/Windows/Autounattend.xml"
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
    error "Packer init for Windows VM '$_vm_type' failed (exit $_packer_init_status)"
    return "$_packer_init_status"
  fi

  _packer_status=1
  _built_tmpdir=''
  while IFS=' ' read -r _firmware_mode _boot_strategy _attempt_timeout; do
    [ -n "$_firmware_mode" ] || continue

    say "Windows Packer attempt using firmware_mode=$_firmware_mode boot_strategy=$_boot_strategy (ssh_timeout=$_attempt_timeout)..."

    # WHY: Packer qemu builder requires a non-existent output_directory.
    _attempt_tmpdir="$(mktemp -d "$(vm_src_path "$_vm_type" ".${_vm_type}.${_firmware_mode}.${_boot_strategy}.XXXXXX")")"
    _tmp_out="$_attempt_tmpdir/output"
    _packer_log="$_attempt_tmpdir/packer.log"
    _autounattend_rendered="$_attempt_tmpdir/Autounattend.xml"
    perl -pe "s/__NUCLEUS_GUEST_USERNAME__/${vm_guest_username}/g; s/__NUCLEUS_GUEST_PASSWORD__/${vm_guest_password}/g; s/__GUEST_HOSTNAME__/$_guest_hostname/g" \
      "$VMS_DIR/Windows/Autounattend.xml" >"$_autounattend_rendered"
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
    error "Packer build for Windows VM '$_vm_type' failed (exit $_packer_status)"
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

  resize_and_mark_image '' "$_marker" "$_type_fp"
  say "Windows 11 image ready: $_out"
}

# vm_build_macos TYPE DISK_BYTES RAM_BYTES CPUS MACOS_VERSION
#   Builds the macOS guest VM using the Packer Tart plugin.  Requires tart
#   and packer to be installed; only runs on Darwin hosts (Tart uses Apple
#   Virtualization.framework which is not available on other platforms).
#   The resulting VM is stored in ~/virtual machines/tart/vms/<name>/ (via
#   the ~/.tart symlink created by ensure_tart_vm_dir).
#   Source: https://github.com/cirruslabs/packer-plugin-tart
vm_build_macos() {
  _vm_type="$1"
  _disk_bytes="$2"
  _ram_bytes="$3"
  _cpus="$4"
  _macos_version="$5"
  _marker="$(vm_type_config_marker_path "$_vm_type")"
  # WHY: the macOS type build bakes guest identity (Tart packer vars) and has
  # no per-VM injection path, so the type marker tracks config and credentials.
  _type_fp="$(vm_type_image_fingerprint "$_vm_type")" || return 1

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

  if vm_get_tart_registered_names | grep -qxF "$_vm_type"; then
    if vm_type_config_marker_matches "$_type_fp" "$_marker"; then
      say "tart VM '$_vm_type' already exists for the current guest config and credentials (owner=$vm_secret_owner, username=$vm_guest_username)"
      return 0
    fi

    say "macOS guest config/credential drift detected; rebuilding tart VM '$_vm_type'"
    if ! tart delete "$_vm_type"; then
      error "failed to delete stale tart VM '$_vm_type' before rebuild"
      return 1
    fi
    rm -f "$_marker"
  fi

  _packer_dir="$VMS_DIR/macOS"
  _disk_gib="$(((_disk_bytes + 999999999) / 1000000000))"
  _mem_gib="$(((_ram_bytes + 1073741823) / 1073741824))"

  say "building macOS $_macos_version VM via Packer Tart (disk=$_disk_gib GiB, mem=$_mem_gib GiB, cpus=$_cpus)..."

  if [ "$dry_run" = true ]; then
    dry_run "cd $_packer_dir && packer build -var vm_name=$_vm_type -var macos_version=$_macos_version -var guest_username=$vm_guest_username -var guest_password=<redacted> -var vm_hostname=$NUCLEUS_VM_GUEST_HOSTNAME -var disk_size_gib=$_disk_gib -var memory_gib=$_mem_gib -var cpus=$_cpus ."
    return 0
  fi

  _packer_status=0
  (
    cd "$_packer_dir"
    packer init .
    packer build \
      -var "vm_name=$_vm_type" \
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
    error "Packer build for macOS VM '$_vm_type' failed (exit $_packer_status)"
    return "$_packer_status"
  fi
  resize_and_mark_image '' "$_marker" "$_type_fp"
  say "macOS VM '$_vm_type' built and registered in tart"
}

# prune_stale_build_dirs
#   Removes orphaned dot-prefixed Packer build temporary directories that may
#   have been left behind by interrupted or crashed builds.
prune_stale_build_dirs() {
  if [ ! -d "$SRC_DIR" ]; then
    return 0
  fi

  for _psbd_type_dir in "$SRC_DIR"/*/; do
    [ -d "$_psbd_type_dir" ] || continue
    for _dir in "$_psbd_type_dir"/.[!.]*/; do
      [ -d "$_dir" ] || continue
      say "removing stale temporary build directory: $_dir"
      rm -rf "$_dir"
    done
  done
}

# vm_build_system TYPE
#   Builds/rebuilds the type-scoped system image (src/<type>/system
#   image.qcow2) once for TYPE, using the first enabled, host-matched manifest
#   entry of TYPE for build parameters (disk size, edition, macOS version).
#   WHY: the type image is identity-free and shared by every VM of the type;
#   per-VM identity is injected onto the data disk at provision time, never
#   baked into the image.
vm_build_system() {
  _bs_type="$1"

  _bs_id="$(jq -r --arg type "$_bs_type" --arg host "$NUCLEUS_HOST" \
    '[.VMs[] | select(.type == $type) | select(.enabled == true) | select(.hosts | contains([$host]))] | .[0].id // empty' \
    "$MANIFEST")"
  if [ -z "$_bs_id" ]; then
    error "no enabled VM of type '$_bs_type' configured for host '$NUCLEUS_HOST'"
    return 1
  fi

  _bs_disk_bytes="$(parse_size "$(jq -r --arg n "$_bs_id" '.VMs[] | select(.id == $n) | .diskSize' "$MANIFEST")")"
  # WHY: the type image is identity-free; the type name is the guest hostname
  # (macOS Tart -var vm_hostname, Windows Autounattend guest hostname token).
  _bs_guest_hostname="$(printf '%s' "$_bs_type" | tr '[:upper:]' '[:lower:]')"
  export NUCLEUS_VM_GUEST_HOSTNAME="$_bs_guest_hostname"

  case "$_bs_type" in
  NixOS)
    # check-suppress:suppression_doc: best-effort -- a prerequisite-missing or build failure for one
    vm_build_nixos "$_bs_type" "$_bs_disk_bytes" ||
      say "NixOS image build skipped for type '$_bs_type' (prerequisite missing or build failed; see above)"
    ;;
  Windows)
    _bs_edition="$(jq -r --arg n "$_bs_id" '.VMs[] | select(.id == $n) | .Windows.edition' "$MANIFEST")"
    # check-suppress:suppression_doc: best-effort -- see NixOS branch above.
    vm_build_windows "$_bs_type" "$_bs_disk_bytes" "$_bs_edition" ||
      say "Windows image build skipped for type '$_bs_type' (prerequisite missing or build failed; see above)"
    ;;
  macOS)
    _bs_ram_bytes="$(parse_size "$(jq -r --arg n "$_bs_id" '.VMs[] | select(.id == $n) | .ram' "$MANIFEST")")"
    _bs_cpus="$(jq -r --arg n "$_bs_id" '.VMs[] | select(.id == $n) | .cpus' "$MANIFEST")"
    _bs_macos_ver="$(jq -r --arg n "$_bs_id" '.VMs[] | select(.id == $n) | .macOS.version' "$MANIFEST")"
    # check-suppress:suppression_doc: best-effort -- see NixOS branch above.
    vm_build_macos "$_bs_type" "$_bs_disk_bytes" "$_bs_ram_bytes" "$_bs_cpus" "$_bs_macos_ver" ||
      say "macOS image build skipped for type '$_bs_type' (prerequisite missing or build failed; see above)"
    ;;
  Android)
    # Android system/GSI images are downloaded per-VM (gsiUrl) by
    # vm_build_android_image; there is no type-scoped Android image.
    return 0
    ;;
  *)
    error "unsupported VM type for system build: $_bs_type"
    return 1
    ;;
  esac
}

vm_build_images() {
  vm_ensure_type_src_dirs
  prune_stale_build_dirs

  # Build each distinct enabled, host-matched type's system image once.
  # WHY: the type image is identity-free and shared by every VM of the type;
  # per-VM identity is injected onto the data disk at provision time.
  while IFS= read -r _bi_type; do
    [ -n "$_bi_type" ] || continue
    if [ "$_bi_type" = "Android" ]; then
      continue
    fi
    vm_build_system "$_bi_type"
  done < <(jq -r --arg host "$NUCLEUS_HOST" \
    '[.VMs[] | select(.enabled == true) | select(.hosts | contains([$host])) | .type] | unique[]' \
    "$MANIFEST")

  # Android keeps the per-VM build path: its system/GSI images are downloaded
  # per id (gsiUrl) and the userdata disk is created per id.
  vm_for_each vm_build_android_image
}

# macOS / Tart (macOS guests)

# vm_setup_tart_vms — Phase 2 provisioning checks for macOS-type VM guests.
#   The Packer Tart build already registered the VM in tart's store; this
#   function validates registration and reports runtime entry points.
#   Source: https://github.com/cirruslabs/tart
vm_setup_tart_vms() {
  if ! command -v tart >/dev/null 2>&1; then
    say "tart not found; skipping macOS VM provisioning"
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

# vm_setup_windows_qemu — Callback for vm_for_each on Windows. Provisions the
#   writable runtime disk per VM: Windows guests get a data/<id>.qcow2 overlay
#   over images/<type>.base.qcow2 (mirroring vm_setup_libvirt and the
#   PowerShell vm-setup Pass A); Android guests get a standalone
#   data/<id>.qcow2 userdata disk (system/GSI images are referenced directly).
vm_setup_windows_qemu() {
  local vm_id="$1" vm_type="$2" vm_hosts="$3" vm_index="$4"
  local vm_display disk_path _prebuilt
  local _prebuilt_min_size
  local _android_userdata _android_disk_bytes _android_virtual_size

  vm_display=$(jq -r ".VMs[$vm_index].name" "$MANIFEST")

  disk_path="$VM_DIR/data/${vm_id}.qcow2"

  say "configuring Windows QEMU VM '$vm_display' (hosts: $vm_hosts)..."

  if [ "$vm_type" = "Android" ]; then
    _android_userdata="$VM_DIR/data/${vm_id}.qcow2"
    _android_disk_bytes="$(parse_size "$(jq -r ".VMs[$vm_index].diskSize" "$MANIFEST")")"
    if [ "$dry_run" = false ]; then
      mkdir -p "$VM_DIR/data"
      if [ ! -f "$_android_userdata" ]; then
        if command -v qemu-img >/dev/null 2>&1; then
          say "creating Android userdata disk for '$vm_id' (${_android_disk_bytes} bytes)"
          if ! qemu-img create -f qcow2 "$_android_userdata" "$_android_disk_bytes" >/dev/null; then
            error "failed to create Android userdata disk: $_android_userdata"
            return
          fi
        else
          warn "qemu-img not found; cannot create Android userdata disk for '$vm_id'"
        fi
      else
        say "Android userdata disk already exists: $_android_userdata"
        if command -v qemu-img >/dev/null 2>&1; then
          _android_virtual_size="$(qemu-img info --output=json "$_android_userdata" | jq -r '."virtual-size" // 0')"
          if [ -n "$_android_virtual_size" ] && [ "$_android_virtual_size" -lt "$_android_disk_bytes" ]; then
            say "growing Android userdata disk for '$vm_id' from $_android_virtual_size to $_android_disk_bytes bytes (grow-only)"
            if ! qemu-img resize "$_android_userdata" "$_android_disk_bytes" >/dev/null; then
              error "failed to grow Android userdata disk: $_android_userdata"
            fi
          fi
        else
          warn "qemu-img not found; cannot grow Android userdata disk for '$vm_id'"
        fi
      fi
    else
      dry_run "ensure Android userdata disk: $_android_userdata (${_android_disk_bytes} bytes)"
    fi
    return
  fi

  _prebuilt="$(vm_src_path "$vm_type" "$VM_SYSTEM_IMAGE")"
  _prebuilt_min_size="$(parse_size "$(jq -r ".VMs[$vm_index].minImageSize" "$MANIFEST")")"
  if [ ! -f "$_prebuilt" ]; then
    warn "image not found: $_prebuilt; skipping '$vm_id'"
    return
  fi
  if ! validate_qcow2_image "$_prebuilt" "pre-built image for ${vm_id}" "$_prebuilt_min_size"; then
    warn "pre-built image is invalid for '$vm_id': $_prebuilt"
    return
  fi

  if [ "$dry_run" = false ]; then
    mkdir -p "$VM_DIR"
    if ! vm_provision_one "$vm_id"; then
      return
    fi
    say "data disk ready: $disk_path"
  else
    dry_run "ensure data disk: $disk_path (overlay on $(vm_src_path "$vm_type" "$VM_SYSTEM_IMAGE"))"
  fi
}

vm_setup_windows_qemu_vms() {
  vm_for_each vm_setup_windows_qemu
  say "Windows VM setup complete; use the generated start-<name> scripts to start VMs"
}

# Garbage collection for non-provisioned VM artifacts

# vm_gc_vms — Top-level GC dispatcher.  Called from the vm.sh main flow
#   when --gc is passed.  Removes VM artifacts (Tart VMs, UTM bundles,
#   libvirt domains, disk images, credential markers, VM descriptors) for
#   VMs not in the expected set.  By default only entries absent from
#   VMs.json entirely are cleared; disabled entries are preserved unless
#   --gc-disabled is passed, which narrows the expected set to
#   enabled-and-host-matched VMs.
vm_gc_vms() {
  # WHY: default GC keeps disabled entries; only names absent from the
  if [ "$gc_disabled_mode" = true ]; then
    _gcv_expected="$(vm_get_expected_vm_ids)" || return
    say "GC — including disabled VM entries (--gc-disabled)..."
  else
    _gcv_expected="$(vm_get_manifest_vm_ids)" || return
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
  vm_gc_orphan_descriptors "$_gcv_expected"

  say "GC — done"
}

# gc_tart_vms EXPECTED_NAMES — Remove Tart VMs not in the expected set.
gc_tart_vms() {
  _gct_expected="$1"
  command -v tart >/dev/null 2>&1 || return

  vm_get_tart_registered_names | while IFS= read -r _gct_name; do
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

# vm_gc_src_keep_set_for_type TYPE EXPECTED_NAMES — Print canonical src/<type>/
#   filenames that must be preserved for expected VMs of TYPE.
vm_gc_src_keep_set_for_type() {
  _gcsksft_type="$1"
  _gcsksft_expected="$2"

  jq -r \
    --arg type "$_gcsksft_type" \
    --arg expected "$_gcsksft_expected" \
    --arg systemImage "$VM_SYSTEM_IMAGE" \
    '
    .VMs[] |
    select(.type == $type) |
    select(.id as $id | ($expected | split("\n") | contains([$id]))) |
    [
      $systemImage,
      (if .Android then
        (.Android.systemImage,
         (if .Android.gsiUrl != null then .Android.gsiImage else empty end))
      else empty end)
    ] | .[]
  ' "$MANIFEST"
}

# vm_gc_disk_keep_set DIR EXPECTED_NAMES — Print the full filenames (with
#   extension) of every disk image under DIR that must be preserved for the
#   expected VMs.  data/ keeps writable disks (<id>.qcow2) when gc_data_mode
#   is enabled.
vm_gc_disk_keep_set() {
  _gcdks_dir="$1"
  _gcdks_expected="$2"

  jq -r --arg expected "$_gcdks_expected" '
    .VMs[] |
    select(.id as $id | ($expected | split("\n") | contains([$id]))) |
    [
      .id + ".qcow2",
      (if .Android then .Android.userdataImage else empty end)
    ] | .[]
  ' "$MANIFEST"
}

# vm_gc_orphan_disks EXPECTED_NAMES — Remove disk images not in the
#   manifest-derived keep-set for the expected VMs (see vm_gc_src_keep_set_for_type
#   and vm_gc_disk_keep_set).
vm_gc_orphan_disks() {
  _gcod_expected="$1"

  for _gcod_type_dir in "$SRC_DIR"/*/; do
    [ -d "$_gcod_type_dir" ] || continue
    _gcod_type="$(basename "$_gcod_type_dir")"
    _gcod_keep="$(vm_gc_src_keep_set_for_type "$_gcod_type" "$_gcod_expected")" || return
    for _gcod_path in "$_gcod_type_dir"*.qcow2; do
      [ -f "$_gcod_path" ] || continue
      _gcod_name="$(basename "$_gcod_path")"
      if ! printf '%s\n' "$_gcod_keep" | grep -qxF "$_gcod_name"; then
        say "GC — removing non-provisioned disk image: $_gcod_path"
        if [ "$dry_run" = false ]; then
          rm -f "$_gcod_path"
        fi
      fi
    done
  done

  if [ "$gc_data_mode" = true ]; then
    _gcod_data_dir="$VM_DIR/data"
    if [ -d "$_gcod_data_dir" ]; then
      _gcod_keep="$(vm_gc_disk_keep_set "$_gcod_data_dir" "$_gcod_expected")" || return
      for _gcod_path in "$_gcod_data_dir"/*.qcow2; do
        [ -f "$_gcod_path" ] || continue
        _gcod_name="$(basename "$_gcod_path")"
        if ! printf '%s\n' "$_gcod_keep" | grep -qxF "$_gcod_name"; then
          say "GC — removing non-provisioned disk image: $_gcod_path"
          if [ "$dry_run" = false ]; then
            rm -f "$_gcod_path"
          fi
        fi
      done
    fi
  fi
}

# vm_gc_orphan_markers EXPECTED_NAMES — Remove guest marker files (type-config
#   and provision fingerprints) that are no longer meaningful.  src/<type>/
#   markers gate the type system image; data/ sidecar markers are removed when
#   their disk image is gone (only when gc_data_mode is enabled).
vm_gc_orphan_markers() {
  _gcom_expected="$1"

  for _gcom_type_dir in "$SRC_DIR"/*/; do
    [ -d "$_gcom_type_dir" ] || continue
    _gcom_type="$(basename "$_gcom_type_dir")"
    _gcom_type_expected=false
    if jq -e --arg type "$_gcom_type" --arg expected "$_gcom_expected" '
      .VMs[] |
      select(.type == $type) |
      select(.id as $id | ($expected | split("\n") | contains([$id])))
    ' "$MANIFEST" >/dev/null 2>&1; then
      _gcom_type_expected=true
    fi
    _gcom_marker="$_gcom_type_dir/${VM_TYPE_MARKER_BASE}.vm-type-config-sha256"
    if [ -f "$_gcom_marker" ]; then
      if [ "$_gcom_type_expected" != true ]; then
        say "GC — removing orphaned guest marker: $_gcom_marker"
        if [ "$dry_run" = false ]; then
          rm -f "$_gcom_marker"
        fi
      fi
    fi
  done

  if [ "$gc_data_mode" = true ]; then
    _gcom_data_dir="$VM_DIR/data"
    [ -d "$_gcom_data_dir" ] || return 0
    for _gcom_marker in "$_gcom_data_dir"/*.vm-provision-sha256; do
      [ -f "$_gcom_marker" ] || continue
      _gcom_base="${_gcom_marker%.vm-provision-sha256}"
      if [ ! -f "$_gcom_base" ]; then
        say "GC — removing orphaned guest marker: $_gcom_marker"
        if [ "$dry_run" = false ]; then
          rm -f "$_gcom_marker"
        fi
      fi
    done
  fi
}

# vm_gc_orphan_descriptors EXPECTED_NAMES — Remove VM descriptors
#   ($VM_DIR/<id>.vm.json) whose guest is not in the expected set.
#   WHY: descriptors are keyed to the expected set rather than to disk
#   existence because macOS/tart guests keep their disks in tart's store;
#   a disk-based check would delete their descriptors on every GC run.
vm_gc_orphan_descriptors() {
  _gcods_expected="$1"

  for _gcods_desc in "$VM_DIR"/*.vm.json; do
    [ -f "$_gcods_desc" ] || continue
    _gcods_name="$(basename "$_gcods_desc" .vm.json)"
    if ! printf '%s\n' "$_gcods_expected" | grep -qxF "$_gcods_name"; then
      say "GC — removing orphaned VM descriptor: $_gcods_desc"
      if [ "$dry_run" = false ]; then
        rm -f "$_gcods_desc"
      fi
    fi
  done
}

# vm_pack_vms — Strip trivially regenerable artifacts from the VM directory
#   so the tree can be copied as-is to another host (nucleus-vm pack).
#   Default is dry-run: prints planned removals.  --force performs them.
#   Refuses while any VM is running.  WHY: pack removes only artifacts that
#   are a pure function of kept inputs plus a trivial command (no downloads,
#   no build time) plus transient junk: UTM bundles (rebuilt by setup from
#   the plist template + ln -f + open), generated start/stop scripts
#   (sed-rendered), and src/<type>/Packer/ + stale dot-dirs (Packer junk).
#   Everything else — data disks, Android userdata, type system images +
#   markers, installer
#   ISOs, descriptors, runtime markers, tart store, README, and the
#   pack/unpack wrappers — is payload or data and stays.
vm_pack_vms() {
  local _pv_running
  _pv_running="$(vm_get_running_ids)"
  if [ -n "$_pv_running" ]; then
    error "cannot pack while a VM is running: $(printf '%s' "$_pv_running" | tr '\n' ' ')"
    return 1
  fi

  if [ "$dry_run" = true ]; then
    dry_run "pack mode enabled — printing planned removals (pass --force to perform)"
  fi

  for _pv_bundle in "$VM_DIR"/*.utm/; do
    [ -d "$_pv_bundle" ] || continue
    say "pack — removing regenerable UTM bundle: $_pv_bundle"
    if [ "$dry_run" = false ]; then
      rm -rf "$_pv_bundle"
    fi
  done

  if [ -d "$VM_DIR/scripts" ]; then
    for _pv_script in "$VM_DIR"/scripts/start-*.sh "$VM_DIR"/scripts/start-*.ps1 "$VM_DIR"/scripts/stop-*.sh "$VM_DIR"/scripts/stop-*.ps1; do
      [ -f "$_pv_script" ] || continue
      say "pack — removing regenerable start/stop script: $_pv_script"
      if [ "$dry_run" = false ]; then
        rm -f "$_pv_script"
      fi
    done
  fi

  for _pv_type_dir in "$SRC_DIR"/*/; do
    [ -d "$_pv_type_dir" ] || continue
    _pv_packer="$_pv_type_dir$VM_PACKER_BUILD_DIR"
    if [ -d "$_pv_packer" ]; then
      say "pack — removing transient Packer directory: $_pv_packer"
      if [ "$dry_run" = false ]; then
        rm -rf "$_pv_packer"
      fi
    fi
    for _pv_dot in "$_pv_type_dir"/.[!.]*/; do
      [ -d "$_pv_dot" ] || continue
      say "pack — removing transient build directory: $_pv_dot"
      if [ "$dry_run" = false ]; then
        rm -rf "$_pv_dot"
      fi
    done
  done

  say "pack — summary: stripped regenerable wrappers; payload retained (src, data, descriptors, tart/, README)"
  say "pack — next: copy the packed tree to the target host, then run 'nucleus-vm unpack' or 'nucleus-vm setup' there"
  if [ "$dry_run" = true ]; then
    say "pack — dry-run: nothing was removed; pass --force to perform"
  fi
}

# vm_unpack_ensure_data_disk NAME TYPE
#   Restores the data disk after pack.  The data disk (data/<name>.qcow2) is
#   recreated only when absent — never rebuilt (its content is user data by
#   design); when present it is kept as-is (pack never removes it).  Backs
#   ../src/<type>/system image.qcow2 directly.  Returns 1 when the type
#   system image is missing (packed trees always carry it, so this signals a
#   broken tree).
vm_unpack_ensure_data_disk() {
  _uedd_name="$1"
  _uedd_type="$2"
  _uedd_system_image="$(vm_src_path "$_uedd_type" "$VM_SYSTEM_IMAGE")"
  _uedd_disk="$VM_DIR/data/${_uedd_name}.qcow2"
  _uedd_backing_rel="$(vm_system_image_rel_path "$_uedd_type")"

  if [ ! -f "$_uedd_system_image" ]; then
    warn "unpack — system image missing: $_uedd_system_image (re-provision or copy it back)"
    return 1
  fi

  if [ "$dry_run" = false ]; then
    mkdir -p "$VM_DIR/data"
    if [ ! -f "$_uedd_disk" ]; then
      say "unpack — recreating absent data disk: $_uedd_disk"
      qemu-img create -f qcow2 -b "$_uedd_backing_rel" -F qcow2 "$_uedd_disk" >/dev/null
    else
      say "unpack — keeping existing data disk: $_uedd_disk"
    fi
  else
    dry_run "ensure data disk for $_uedd_name (recreated only if absent; backing $_uedd_system_image)"
  fi
}

# vm_unpack_vms — Regenerate per-platform VM artifacts from the descriptors
#   (<id>.vm.json) in the VM directory, after copying a packed tree to a
#   target host (nucleus-vm unpack; complements vm_pack_vms).  For EVERY
#   descriptor — enabled or disabled — start/stop helper scripts (BOTH .sh
#   and .ps1 variants) are re-rendered from the descriptor fields via
#   vm_write_start_script/vm_write_stop_script, and the pack/unpack wrappers
#   are refreshed.  Bundle/domain creation happens only for enabled
#   descriptors (mirrors setup): UTM (Darwin) re-creates the bundle dir +
#   cp the Nix-rendered plist template + chmod +w + link disks into Data/ +
#   open + wait for registration; libvirt (Linux) virsh define + ensure
#   data disks; Windows re-renders start scripts (PowerShell).  Dependency:
#   the target's nucleus config must be applied (provides the plist/domain
#   templates); copied data files are consumed as-is — never modified.
vm_unpack_vms() {
  if [ "$dry_run" = true ]; then
    dry_run "unpack mode enabled — printing planned regeneration (pass --force to perform)"
  fi

  _uv_desc_count=0
  for _uv_desc in "$VM_DIR"/*.vm.json; do
    [ -f "$_uv_desc" ] || continue
    _uv_desc_count=$((_uv_desc_count + 1))
  done
  if [ "$_uv_desc_count" -eq 0 ]; then
    say "unpack — no descriptors found in $VM_DIR; run 'nucleus-vm setup' to write them"
    return 0
  fi

  for _uv_desc in "$VM_DIR"/*.vm.json; do
    [ -f "$_uv_desc" ] || continue
    _uv_name="$(jq -r '.id' "$_uv_desc")"
    if [ -z "$_uv_name" ] || [ "$_uv_name" = "null" ]; then
      warn "unpack — descriptor without an id, skipping: $_uv_desc"
      continue
    fi
    _uv_type="$(jq -r '.type' "$_uv_desc")"
    _uv_enabled="$(jq -r '.enabled // false' "$_uv_desc")"
    _uv_host_kind="$(vm_script_host_kind "$_uv_type")" || return 1

    vm_write_start_script "$(cat "$_uv_desc")" "$_uv_host_kind"
    vm_write_stop_script "$(cat "$_uv_desc")" "$_uv_host_kind"

    if [ "$_uv_enabled" != "true" ]; then
      say "unpack — descriptor '$_uv_name' is disabled; scripts rendered, no bundle/domain"
      continue
    fi
    case "$(uname -s)" in
    Darwin)
      if [ "$_uv_type" = "macOS" ]; then
        say "unpack — macOS/tart guest '$_uv_name' is managed by Tart; nothing else to regenerate"
        continue
      fi
      _uv_bundle="$VM_DIR/${_uv_name}.utm"
      _uv_plist_template="${HOME}/.local/share/nucleus/vms/${_uv_name}-config.plist"
      if [ ! -f "$_uv_plist_template" ]; then
        warn "unpack — UTM config template not found: $_uv_plist_template (apply the macOS config on this host first)"
        continue
      fi
      say "unpack — recreating UTM bundle from descriptor: $_uv_bundle"
      if [ "$dry_run" = false ]; then
        if [ -e "$_uv_bundle" ]; then
          say "unpack — removing stale UTM bundle: $_uv_bundle"
          rm -rf "$_uv_bundle"
        fi
        mkdir -p "$_uv_bundle/Data"
        if [ "$_uv_type" = "Android" ]; then
          _uv_android_system="$(vm_src_path "$_uv_type" "$(jq -r '.Android.systemImage' "$_uv_desc")")"
          _uv_android_userdata="$VM_DIR/data/$(jq -r '.Android.userdataImage' "$_uv_desc")"
          _uv_android_gsi="$(vm_src_path "$_uv_type" "$(jq -r '.Android.gsiImage' "$_uv_desc")")"
          _uv_gsi_url="$(jq -r '.Android.gsiUrl' "$_uv_desc")"
          if [ ! -f "$_uv_android_userdata" ]; then
            warn "unpack — Android userdata missing: $_uv_android_userdata; skipping bundle for '$_uv_name'"
            continue
          fi
          cp "$_uv_android_system" "$_uv_bundle/Data/disk-main.qcow2"
          ln -f "$_uv_android_userdata" "$_uv_bundle/Data/$(basename "$_uv_android_userdata")"
          if [ -n "$_uv_gsi_url" ] && [ "$_uv_gsi_url" != "null" ] && [ -f "$_uv_android_gsi" ]; then
            cp "$_uv_android_gsi" "$_uv_bundle/Data/$(basename "$_uv_android_gsi")"
          fi
        else
          if ! vm_unpack_ensure_data_disk "$_uv_name" "$_uv_type"; then
            continue
          fi
          ln -f "$VM_DIR/data/${_uv_name}.qcow2" "$_uv_bundle/Data/disk-main.qcow2"
        fi
        cp "$_uv_plist_template" "$_uv_bundle/config.plist"
        chmod +w "$_uv_bundle/config.plist"
        if ! vm_get_utm_registered_names | grep -qxF "$_uv_name"; then
          say "opening UTM bundle in place: $_uv_bundle"
          if open "$_uv_bundle"; then
            if wait_for_utm_registration "$_uv_name"; then
              say "UTM VM opened and registered: $_uv_name"
            else
              warn "UTM did not register VM '$_uv_name' within timeout; open UTM and retry vm-unpack"
            fi
          else
            warn "opening $_uv_bundle failed; ensure UTM can access the managed VM directory and retry"
          fi
        else
          say "UTM VM already registered: $_uv_name"
        fi
      else
        dry_run "recreate UTM bundle $_uv_bundle (cp plist template + link disks into Data/ + open)"
      fi
      ;;
    Linux)
      _uv_xml_file="/etc/nucleus/vms/${_uv_name}-domain.xml"
      if [ ! -f "$_uv_xml_file" ]; then
        warn "unpack — libvirt domain XML not found: $_uv_xml_file (apply the NixOS config on this host first)"
        continue
      fi
      say "unpack — defining libvirt domain from descriptor: $_uv_name"
      if [ "$dry_run" = false ]; then
        if [ "$_uv_type" = "Android" ]; then
          _uv_android_system="$(vm_src_path "$_uv_type" "$(jq -r '.Android.systemImage' "$_uv_desc")")"
          _uv_android_userdata="$VM_DIR/data/$(jq -r '.Android.userdataImage' "$_uv_desc")"
          _uv_android_gsi="$(vm_src_path "$_uv_type" "$(jq -r '.Android.gsiImage' "$_uv_desc")")"
          _uv_gsi_url="$(jq -r '.Android.gsiUrl' "$_uv_desc")"
          if [ ! -f "$_uv_android_system" ] || [ ! -f "$_uv_android_userdata" ]; then
            warn "unpack — Android images missing for '$_uv_name': $_uv_android_system, $_uv_android_userdata"
            continue
          fi
          if [ -n "$_uv_gsi_url" ] && [ "$_uv_gsi_url" != "null" ] && [ -f "$_uv_android_gsi" ]; then
            say "unpack — Android GSI present: $_uv_android_gsi"
          fi
        else
          if ! vm_unpack_ensure_data_disk "$_uv_name" "$_uv_type"; then
            continue
          fi
        fi
        virsh define "$_uv_xml_file"
      else
        dry_run "define libvirt domain from $_uv_xml_file"
      fi
      ;;
    MINGW* | MSYS* | CYGWIN*)
      say "unpack — Windows host: start/stop scripts re-rendered above; no bundle/domain to regenerate for '$_uv_name'"
      ;;
    esac
  done

  vm_write_pack_unpack_scripts

  say "unpack — summary: regenerated wrappers for $_uv_desc_count descriptor(s) in $VM_DIR"
  if [ "$dry_run" = true ]; then
    say "unpack — dry-run: nothing was regenerated; pass --force to perform"
  fi
}
