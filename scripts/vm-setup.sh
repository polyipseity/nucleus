#!/usr/bin/env bash
# Phase 1 builds pre-built QCOW2 OS images (if absent). Phase 2 provisions
# VM bundles/domains from those images.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT="$(resolve_nucleus_root)"
MANIFEST="$REPO_ROOT/src/modules/VMs.json"
VMS_DIR="$REPO_ROOT/src/vms"
# shellcheck disable=SC2034 # consumed by vm-setup/lib.sh (shellcheck can't follow sourced file)
TEMPLATES_DIR="$VMS_DIR/templates"

dry_run=false
# shellcheck disable=SC2034 # consumed by vm-setup/lib.sh
windows_iso=''
windows_iso_source='auto'
windows_iso_retries='0'
# shellcheck disable=SC2034 # consumed by vm-setup/lib.sh
windows_headless='true'
accelerator=''
gc=false

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
EOF
}

# shellcheck disable=SC2034 # consumed by vm-setup/lib.sh (shellcheck can't follow sourced file)
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
    *)
      printf '%s\n' "vm-setup: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$windows_iso_source" in
  auto|url|fido|'') ;;
  *)
    printf 'vm-setup: invalid --windows-iso-source value: %s\n' "$windows_iso_source" >&2
    printf 'vm-setup: expected one of: auto, url, fido\n' >&2
    exit 1
    ;;
esac

case "$windows_iso_retries" in
  ''|*[!0-9]*)
    printf 'vm-setup: invalid --windows-iso-retries value: %s\n' "$windows_iso_retries" >&2
    printf 'vm-setup: expected a non-negative integer\n' >&2
    exit 1
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
  printf 'vm-setup: manifest not found at %s; skipping\n' "$MANIFEST" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'vm-setup: jq not found in PATH; cannot parse manifest\n' >&2
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
    printf 'vm-setup: could not determine the per-user VM secret owner (set NUCLEUS_VM_SECRET_OWNER to override)\n' >&2
    return 1
  fi

  if ! command -v sops >/dev/null 2>&1; then
    printf 'vm-setup: sops not found in PATH; cannot resolve VM guest credentials from SOPS\n' >&2
    return 1
  fi

  if [ ! -f "$_rvgc_users_json" ]; then
    printf 'vm-setup: users registry not found: %s\n' "$_rvgc_users_json" >&2
    return 1
  fi

  _rvgc_secret_file="$REPO_ROOT/src/secrets/users-${_rvgc_owner}.yml"
  if [ ! -f "$_rvgc_secret_file" ]; then
    printf 'vm-setup: per-user VM secret file not found: %s\n' "$_rvgc_secret_file" >&2
    return 1
  fi

  _rvgc_username_key="$(jq -r --arg owner "$_rvgc_owner" '.[ $owner ].vmGuest.usernameSecretKey // empty' "$_rvgc_users_json")"
  _rvgc_password_key="$(jq -r --arg owner "$_rvgc_owner" '.[ $owner ].vmGuest.passwordSecretKey // empty' "$_rvgc_users_json")"
  if [ -z "$_rvgc_username_key" ] || [ -z "$_rvgc_password_key" ]; then
    printf 'vm-setup: vmGuest secret-key references are missing for user %s in %s\n' "$_rvgc_owner" "$_rvgc_users_json" >&2
    return 1
  fi

  if ! _rvgc_secret_json="$(sops --decrypt --output-type json "$_rvgc_secret_file")"; then
    printf 'vm-setup: failed to decrypt per-user VM secret file: %s\n' "$_rvgc_secret_file" >&2
    return 1
  fi

  vm_secret_owner="$_rvgc_owner"
  vm_guest_username="$(printf '%s' "$_rvgc_secret_json" | jq -r --arg key "$_rvgc_username_key" '.[ $key ] // empty')"
  vm_guest_password="$(printf '%s' "$_rvgc_secret_json" | jq -r --arg key "$_rvgc_password_key" '.[ $key ] // empty')"

  if [ -z "$vm_guest_username" ] || [ -z "$vm_guest_password" ]; then
    printf 'vm-setup: vmGuest secret values are missing in %s for user %s\n' "$_rvgc_secret_file" "$_rvgc_owner" >&2
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

  printf 'vm-setup: no SHA-256 tool is available; cannot track VM guest credential drift\n' >&2
  return 1
}

if ! resolve_vm_guest_credentials; then
  exit 0
fi

# shellcheck disable=SC2034 # consumed by vm-setup/lib.sh below
# shellcheck disable=SC2034 # consumed by vm-setup/lib.sh below
if ! vm_guest_credentials_fingerprint="$(vm_guest_credentials_hash)"; then
  exit 0
fi

export NUCLEUS_VM_GUEST_USERNAME="$vm_guest_username"
export NUCLEUS_VM_GUEST_PASSWORD="$vm_guest_password"


# Source shared VM setup library (function definitions).
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/vm-setup/lib.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf 'vm-setup: reading manifest from %s\n' "$MANIFEST"
printf 'vm-setup: guest credential policy active (owner=%s, username=%s, source=SOPS)\n' "$vm_secret_owner" "$vm_guest_username"
if [ "$dry_run" = true ]; then
  printf 'vm-setup: dry-run mode — no changes will be made\n'
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

printf 'vm-setup: phase 1 \u2014 building images...\n'
build_images

printf 'vm-setup: phase 2 \u2014 provisioning VMs...\n'
if [ -d "$VM_DIR/scripts" ]; then
  for _prune_f in "$VM_DIR/scripts"/*.sh "$VM_DIR/scripts"/*.ps1; do
    [ -f "$_prune_f" ] || continue
    printf 'vm-setup: removed stale script: %s\n' "$_prune_f"
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
      printf 'vm-setup: unsupported Linux host outside NixOS; no provisioning actions executed\n'
    fi
    ;;
  *)
    printf 'vm-setup: unsupported OS "%s"; nothing to do\n' "$_os"
    ;;
esac

if [ "$gc" = true ]; then
  gc_vms
fi

printf 'vm-setup: done\n'
