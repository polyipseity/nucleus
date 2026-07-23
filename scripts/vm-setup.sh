#!/usr/bin/env bash
# Phase 1 builds pre-built QCOW2 OS images (if absent). Phase 2 provisions
# VM bundles/domains from those images.
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

REPO_ROOT="$(derive_repo_root)"
MANIFEST="$REPO_ROOT/src/modules/VMs.json"
VMS_DIR="$REPO_ROOT/src/vms"
TEMPLATES_DIR="$VMS_DIR/templates"

dry_run=false
windows_iso=''
windows_iso_source='auto'
windows_iso_retries='0'
windows_headless='true'
accelerator=''
gc=false
accept_gsi_license=false
upgrade_android=false
reset_userdata=false

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  --dry-run                  Print planned actions without executing (default: off).
  --mido-patch-file PATH     Override runtime patch file path (default: src/vms/windows/patches/mido-iso-link.patch).
  --mido-script PATH         Override the Mido script path (default: vendored script).
  --windows-iso PATH         Path to the Windows 11 ISO.
  --no-windows-iso           Skip using a Windows ISO (default: off).
  --windows-iso-source S     ISO auto-resolution: auto|url|fido (default: auto).
  --no-windows-iso-source    Skip Windows ISO auto-resolution (default: off).
  --windows-iso-retries N    Retry attempts for network downloads (default: 0).
  --headful|--no-headful     Run guest builds with visible GUI (--headful) or headless (--no-headful, default: on).
  --vm-dir-override PATH     Override the default ~/virtual machines path.
  --gc|--no-gc               Remove non-provisioned VM artifacts (default: --no-gc).
  --accept-gsi-license|--no-accept-gsi-license
                             Accept the GSI license for Android GSI downloads (default: --no-accept-gsi-license).
  --upgrade-android|--no-upgrade-android
                             Force re-download and replace the Android system image (default: --no-upgrade-android).
  --reset-userdata|--no-reset-userdata
                             Reset Android userdata disk (factory reset; default: --no-reset-userdata).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)      dry_run=true ;;
    --mido-patch-file)    NUCLEUS_MIDO_PATCH_FILE="$2"; shift ;;
    --mido-script)        NUCLEUS_MIDO_SCRIPT="$2"; shift ;;
    --windows-iso)  windows_iso="$2"; shift ;;
    --no-windows-iso)     windows_iso='' ;;
    --windows-iso-source) windows_iso_source="$2"; shift ;;
    --no-windows-iso-source) windows_iso_source='' ;;
    --windows-iso-retries) windows_iso_retries="$2"; shift ;;
    --headful)      windows_headless='false' ;;
    --no-headful)   windows_headless='true' ;;
    --repo-root)    REPO_ROOT="$2"; shift ;;
    --vm-dir-override)    VM_DIR_OVERRIDE="$2"; shift ;;
    --accelerator)  accelerator="$2"; shift ;;
    --gc)           gc=true ;;
    --no-gc)        gc=false ;;
    --accept-gsi-license) accept_gsi_license=true ;;
    --no-accept-gsi-license) accept_gsi_license=false ;;
    --upgrade-android)  upgrade_android=true ;;
    --no-upgrade-android) upgrade_android=false ;;
    --reset-userdata)   reset_userdata=true ;;
    --no-reset-userdata) reset_userdata=false ;;
    *)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$windows_iso_source" in
  auto|url|fido|'') ;;
  *)
    error "invalid --windows-iso-source value: $windows_iso_source; expected one of: auto, url, fido"
    ;;
esac

case "$windows_iso_retries" in
  ''|*[!0-9]*)
    error "invalid --windows-iso-retries value: $windows_iso_retries; expected a non-negative integer"
    ;;
esac

# Auto-detect QEMU accelerator for this host platform.
if [ -z "$accelerator" ]; then
  case "$(uname -s)" in
    Darwin)
      if [ "$(uname -m)" = "arm64" ]; then
        # WHY: Hypervisor.framework on Apple Silicon (arm64) only accelerates
        # AArch64 guests; qemu-system-x86_64 -accel hvf fails immediately with
        # "invalid accelerator hvf".  Windows x86_64 builds must use software
        # emulation (tcg) instead — slow but correct.  macOS guests use Tart
        # (Virtualization.framework) independently of this accelerator setting.
        accelerator='tcg'
      else
        accelerator='hvf'
      fi
      ;;
    Linux)  accelerator='kvm' ;;
    *)      accelerator='tcg' ;;
  esac
fi

NUCLEUS_HOST="$(resolve_nucleus_host)"
export NUCLEUS_HOST

if [ ! -f "$MANIFEST" ]; then
  say "manifest not found at $MANIFEST; skipping"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq not found in PATH; cannot parse manifest"
  exit 0
fi

VM_DIR="${VM_DIR_OVERRIDE:-$HOME/virtual machines}"
IMAGES_DIR="$VM_DIR/images"

current_vm_secret_owner() {
  if [ -n "${NUCLEUS_VM_SECRET_OWNER:-}" ]; then
    printf '%s\n' "$NUCLEUS_VM_SECRET_OWNER"
    return 0
  fi

  if [ -n "${USER:-}" ]; then
    printf '%s\n' "$USER"
    return 0
  fi

  if command -v id >/dev/null 2>&1; then
    id -un
    return 0
  fi

  return 1
}

resolve_vm_guest_credentials() {
  _rvgc_owner=''
  _rvgc_users_json="$REPO_ROOT/src/modules/users.json"
  _rvgc_secret_file=''

  if _rvgc_owner="$(current_vm_secret_owner)"; then
    :
  else
    _rvgc_owner=''
  fi

  if [ -z "$_rvgc_owner" ]; then
    error "could not determine the per-user VM secret owner (set NUCLEUS_VM_SECRET_OWNER to override)"
  fi

  if ! command -v sops >/dev/null 2>&1; then
    error "sops not found in PATH; cannot resolve VM guest credentials from SOPS"
  fi

  if [ ! -f "$_rvgc_users_json" ]; then
    error "users registry not found: $_rvgc_users_json"
  fi

  _rvgc_secret_file="$REPO_ROOT/src/secrets/users-${_rvgc_owner}.yml"
  if [ ! -f "$_rvgc_secret_file" ]; then
    error "per-user VM secret file not found: $_rvgc_secret_file"
  fi

  _rvgc_username_key="$(jq -r --arg owner "$_rvgc_owner" '.[ $owner ].vmGuest.usernameSecretKey // empty' "$_rvgc_users_json")"
  _rvgc_password_key="$(jq -r --arg owner "$_rvgc_owner" '.[ $owner ].vmGuest.passwordSecretKey // empty' "$_rvgc_users_json")"
  if [ -z "$_rvgc_username_key" ] || [ -z "$_rvgc_password_key" ]; then
    error "vmGuest secret-key references are missing for user $_rvgc_owner in $_rvgc_users_json"
  fi

  if ! _rvgc_secret_json="$(sops --decrypt --output-type json "$_rvgc_secret_file")"; then
    error "failed to decrypt per-user VM secret file: $_rvgc_secret_file"
  fi

  vm_secret_owner="$_rvgc_owner"
  vm_guest_username="$(printf '%s' "$_rvgc_secret_json" | jq -r --arg key "$_rvgc_username_key" '.[ $key ] // empty')"
  vm_guest_password="$(printf '%s' "$_rvgc_secret_json" | jq -r --arg key "$_rvgc_password_key" '.[ $key ] // empty')"

  if [ -z "$vm_guest_username" ] || [ -z "$vm_guest_password" ]; then
    error "vmGuest secret values are missing in $_rvgc_secret_file for user $_rvgc_owner"
    return 1
  fi

  return 0
}

vm_guest_credentials_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n%s' "$vm_guest_username" "$vm_guest_password" | sha256sum | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n%s' "$vm_guest_username" "$vm_guest_password" | shasum -a 256 | awk '{print $1}'
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    printf '%s\n%s' "$vm_guest_username" "$vm_guest_password" | openssl dgst -sha256 | awk '{print $NF}'
    return 0
  fi

  error "no SHA-256 tool is available; cannot track VM guest credential drift"
  return 1
}

if ! resolve_vm_guest_credentials; then
  exit 0
fi

if ! vm_guest_credentials_fingerprint="$(vm_guest_credentials_hash)"; then
  exit 0
fi

export NUCLEUS_VM_GUEST_USERNAME="$vm_guest_username"
export NUCLEUS_VM_GUEST_PASSWORD="$vm_guest_password"


# Source shared VM setup library (function definitions).
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../src/scripts/lib/vm-setup-lib.sh
. "$SCRIPT_DIR/../src/scripts/lib/vm-setup-lib.sh"
vm_setup_init "$REPO_ROOT" "$VM_DIR" "$IMAGES_DIR" "$TEMPLATES_DIR" \
  "$dry_run" "$windows_iso" "$windows_iso_source" "$windows_iso_retries" \
  "$windows_headless" "$accelerator" "$vm_secret_owner" "$vm_guest_username" \
  "$vm_guest_password" "$vm_guest_credentials_fingerprint" \
  "${NUCLEUS_MIDO_PATCH_FILE:-}" "${NUCLEUS_MIDO_SCRIPT:-}" \
  "$accept_gsi_license" \
  "$upgrade_android" \
  "$reset_userdata"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

say "reading manifest from $MANIFEST"
say "guest credential policy active (owner=$vm_secret_owner, username=$vm_guest_username, source=SOPS)"
if [ "$dry_run" = true ]; then
  say "dry-run mode — no changes will be made"
fi

if [ "$dry_run" = false ]; then
  mkdir -p "$VM_DIR"
  mkdir -p "$IMAGES_DIR"
  mkdir -p "$VM_DIR/scripts"
  write_vm_directory_readme

  if [ "$(uname -s)" = "Darwin" ]; then
    ensure_tart_vm_dir
    ensure_utm_default_vm_location
  fi
fi

_packer_status=0
say "phase 1 — building images..."
build_images

say "phase 2 — provisioning VMs..."
if [ -d "$VM_DIR/scripts" ]; then
  for _prune_f in "$VM_DIR/scripts"/*.sh "$VM_DIR/scripts"/*.ps1; do
    [ -f "$_prune_f" ] || continue
    say "removed stale script: $_prune_f"
    rm -f "$_prune_f"
  done
fi
_os=$(uname -s)
case "$_os" in
  Darwin)
    setup_tart_vms
    setup_utm_vms
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      setup_libvirt_vms
    else
      say "unsupported Linux host outside NixOS; no provisioning actions executed"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    setup_windows_qemu_vms
    ;;
  *)
    say "unsupported OS '$_os'; nothing to do"
    ;;
esac

if [ "$gc" = true ]; then
  gc_vms
fi

nuc_done
