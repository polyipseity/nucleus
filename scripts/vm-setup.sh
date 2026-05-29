#!/usr/bin/env sh
# scripts/vm-setup.sh — Build VM images (if needed) and provision VMs.
#
# Combines the former nucleus-VM-build and nucleus-vm-setup into one command.
# Phase 1 builds pre-built QCOW2 OS images (if absent) using
# nixos-generators (NixOS guest on macOS/NixOS) or Packer (Windows).
# Phase 2 provisions VM bundles/domains from those images.
#
# Usage:
#   scripts/vm-setup.sh [options]
#
# Options:
#   --dry-run              Print planned actions without executing.
#   --nixos-only           Build and provision only the NixOS guest.
#   --windows-only         Build and provision only the Windows 11 guest.
#   --windows-iso PATH     Path to the Windows 11 ISO (required for Windows
#                          guest builds). Download from:
#                          https://www.microsoft.com/software-download/windows11
#   --windows-iso-source S Source for Windows ISO auto-resolution when
#                          --windows-iso is omitted: auto|url|mido.
#   --windows-iso-retries N Retry attempts for Windows ISO network downloads
#                          (default: 0, which means a single attempt).
#   --debug-headful        Run Windows Packer QEMU builds with a visible GUI
#                          window (headless=false) for interactive debugging.
#   --accelerator TYPE     QEMU accelerator for image builds (hvf/kvm/tcg).
#                          Defaults: hvf on macOS, kvm on Linux.
#
# Environment variables:
#   VM_DIR_OVERRIDE  override the default ~/virtual machines path
#   NUCLEUS_MIDO_SCRIPT      override the Mido script path (default: vendored script)
#   NUCLEUS_MIDO_PATCH_FILE  override runtime patch file path (default: vms/windows/patches/mido-iso-link.patch)
#
# Prerequisites:
#   NixOS guest    : nix (for nix run github:nix-community/nixos-generators).
#   Windows guest  : packer (pkgs.packer), QEMU, ISO auto-fetched via Fido.
#   macOS guest    : tart (brew install cirruslabs/cli/tart), packer; macOS host only.
#   macOS host     : UTM installed (/Applications/UTM.app); qemu-img in PATH.
#   NixOS host     : libvirtd enabled (vms.nix); qemu-img and virsh in PATH.
#
# Exit: always 0 (best-effort — a VM setup failure does not roll back a
#       completed system apply).
#
# Run as alias:
#   nucleus-vm-setup  (equivalent to scripts/vm-setup.sh)
#
# Source: https://github.com/nix-community/nixos-generators
#         https://developer.hashicorp.com/packer/plugins/builders/qemu
#         https://github.com/cirruslabs/packer-plugin-tart
#         https://github.com/pbatard/Fido

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/src/modules/VMs.json"
VMS_DIR="$REPO_ROOT/vms"

dry_run=false
nixos_only=false
windows_only=false
windows_iso=''
windows_iso_source='auto'
windows_iso_retries='0'
windows_headless='true'
accelerator=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)      dry_run=true ;;
    --nixos-only)   nixos_only=true ;;
    --windows-only) windows_only=true ;;
    --windows-iso)  windows_iso="$2"; shift ;;
    --windows-iso-source) windows_iso_source="$2"; shift ;;
    --windows-iso-retries) windows_iso_retries="$2"; shift ;;
    --debug-headful) windows_headless='false' ;;
    --accelerator)  accelerator="$2"; shift ;;
    *)
      printf 'vm-setup: unknown argument: %s\n' "$1" >&2
      printf 'vm-setup: usage: %s [--dry-run] [--nixos-only|--windows-only] [--windows-iso PATH] [--windows-iso-source auto|url|mido] [--windows-iso-retries N] [--debug-headful] [--accelerator TYPE]\n' "$0" >&2
      exit 1
      ;;
  esac
  shift
done

case "$windows_iso_source" in
  auto|url|mido) ;;
  *)
    printf 'vm-setup: invalid --windows-iso-source value: %s\n' "$windows_iso_source" >&2
    printf 'vm-setup: expected one of: auto, url, mido\n' >&2
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

# write_vm_directory_readme
#   Writes a cross-host usage guide into the managed VM directory so operators
#   can transfer VM artifacts between hosts and run guest-specific converge
#   commands without relying on generated helper scripts.
write_vm_directory_readme() {
  _wvdr_readme="$VM_DIR/README.md"
  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] write VM directory guide: %s\n' "$_wvdr_readme"
    return 0
  fi

  cat >"$_wvdr_readme" <<'EOF'
# virtual machines

This directory stores VM artifacts managed by `nucleus-vm-setup`.

## Layout

- `.tart/` — Tart VM store on macOS hosts (symlinked from `~/.tart`).
- `images/` — build outputs, temporary build directories, and installer cache.
- `images/<name>.qcow2` — pre-built guest images produced in build phase.
- `images/<name>-build/` — temporary Packer output directory used during builds.
- `images/<name>-installer.iso` — cached Windows installer ISO used by rebuilds.
- `<name>.utm/` — UTM bundle directory on macOS hosts.
- `<name>.qcow2` — libvirt/QEMU runtime disk on Linux/Windows hosts.

## Start commands

- macOS guest (Tart): run `~/virtual machines/start-<name>.sh` or `~/virtual machines/start-<name>.ps1`
- NixOS/Windows guests on macOS (UTM): run `~/virtual machines/start-<name>.sh` or `~/virtual machines/start-<name>.ps1`
- NixOS/Windows guests on NixOS (libvirt): run `~/virtual machines/start-<name>.sh` or `~/virtual machines/start-<name>.ps1`
- NixOS/Windows guests on Windows (QEMU): run `start-<name>.ps1` (or `start-<name>.sh` in Git Bash/MSYS)

## UTM bundle portability

`*.utm` is a folder bundle (not a single opaque file). It contains VM metadata
plus disk data (typically `Data/disk-main.qcow2`).

To move a UTM VM to another macOS host:

1. Copy the entire `<name>.utm` directory.
2. Place it under `~/virtual machines/` on the target host.
3. Import it in UTM (or re-run `nucleus-vm-setup` so import automation can detect it).

Copying only `config.plist` or only `disk-main.qcow2` is not sufficient for a
portable UTM VM transfer.

## Guest configuration

Guest OS configuration is **not automatic** after first boot.
Run the generated helper script in `~/virtual machines/` to print the exact
guest-side converge command:

- `~/virtual machines/configure-<name>.sh`
- `~/virtual machines/configure-<name>.ps1`

The converge commands are run inside each guest:

- NixOS guest: `sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"`
- Windows guest: `.\src\hosts\Windows\apply.ps1` (from `%USERPROFILE%\dev\nucleus`)
- macOS guest: `~/dev/nucleus/scripts/bootstrap.sh apply`

## Safe cleanup

Temporary files/directories that are safe to remove when builds fail, are
interrupted, or when reclaiming space:

- `~/virtual machines/images/<name>-build/`
- `~/virtual machines/images/<name>-installer.iso`

Persistent VM artifacts (remove only when intentionally deleting a VM):

- `~/virtual machines/images/<name>.qcow2`
- `~/virtual machines/.tart/`
- `~/virtual machines/<name>.utm/`
- `~/virtual machines/<name>.qcow2`

If the installer cache is removed, `nucleus-vm-setup` re-downloads it on the
next run.

## Notes

- Keep this directory managed by `nucleus-vm-setup`; avoid hand-editing generated artifacts.
- Re-run `nucleus-vm-setup` after changing `src/modules/VMs.json`.
- macOS guest images are built and run with Tart today; automated Tart→UTM runtime handoff is not yet supported.
EOF
  printf 'vm-setup: wrote VM directory guide: %s\n' "$_wvdr_readme"
}

# ensure_utm_default_vm_location
#   Best-effort default-location wiring for UTM by linking ~/Documents/UTM to
#   the managed ~/virtual machines directory when safe.
ensure_utm_default_vm_location() {
  _eudvl_utm_docs="$HOME/Documents/UTM"

  if [ -L "$_eudvl_utm_docs" ]; then
    _eudvl_target="$(readlink "$_eudvl_utm_docs" 2>/dev/null || true)"
    if [ "$_eudvl_target" = "$VM_DIR" ]; then
      printf 'vm-setup: UTM default VM location already points to %s\n' "$VM_DIR"
    else
      printf 'vm-setup: WARNING — %s is a symlink to %s; expected %s\n' \
        "$_eudvl_utm_docs" "$_eudvl_target" "$VM_DIR" >&2
    fi
    return 0
  fi

  if [ -d "$_eudvl_utm_docs" ]; then
    # WHY: preserve existing user-managed UTM document stores; only replace an
    # empty directory to avoid destructive moves.
    if [ -n "$(find "$_eudvl_utm_docs" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      printf 'vm-setup: WARNING — %s is non-empty; cannot auto-link to %s\n' \
        "$_eudvl_utm_docs" "$VM_DIR" >&2
      return 0
    fi
    rmdir "$_eudvl_utm_docs"
  fi

  ln -s "$VM_DIR" "$_eudvl_utm_docs"
  printf 'vm-setup: linked UTM default VM location: %s -> %s\n' "$_eudvl_utm_docs" "$VM_DIR"
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
    _etd_current="$(readlink "$_etd_default" 2>/dev/null || true)"
    if [ "$_etd_current" = "$_etd_target" ]; then
      printf 'vm-setup: tart storage already linked: %s -> %s\n' "$_etd_default" "$_etd_target"
    else
      printf 'vm-setup: WARNING — %s is a symlink to %s (expected %s); not relinking\n' \
        "$_etd_default" "$_etd_current" "$_etd_target" >&2
    fi
    return 0
  fi

  if [ -d "$_etd_default" ]; then
    # WHY: migrate existing ~/.tart to VM_DIR on first run so existing VMs are
    # not lost when this policy was introduced.
    # Use rsync --no-specials to skip Unix socket files (e.g. control.sock)
    # which cp -a cannot copy and which are not persistent data.
    printf 'vm-setup: migrating ~/.tart to %s...\n' "$_etd_target"
    rsync -a --no-specials --no-devices "$_etd_default/" "$_etd_target/"
    rm -rf "$_etd_default"
  fi

  ln -s "$_etd_target" "$_etd_default"
  printf 'vm-setup: linked tart storage: %s -> %s\n' "$_etd_default" "$_etd_target"
}

# should_include TYPE — returns 0 if a VM of the given type should be processed.
should_include() {
  _type="$1"
  if [ "$nixos_only" = true ] && [ "$_type" != "NixOS" ]; then
    return 1
  fi
  if [ "$windows_only" = true ] && [ "$_type" != "Windows" ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] %s\n' "$*"
  else
    "$@"
  fi
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

    printf 'vm-setup: %s failed (attempt %s/%s); retrying in %ss\n' \
      "$_rwb_label" "$_rwb_attempt" "$_rwb_max" "$_rwb_sleep" >&2
    sleep "$_rwb_sleep"
    _rwb_attempt=$((_rwb_attempt + 1))
  done

  return 1
}

# write_start_script NAME DISPLAY TYPE HOST_KIND
# Args:
#   $1 — VM machine name (manifest .name)
#   $2 — VM display name (manifest .display)
#   $3 — VM type (macOS/NixOS/Windows/...)
#   $4 — host runtime kind (darwin-utm|darwin-tart|nixos-libvirt)
# Writes a host-side helper script to start the VM runtime from ~/virtual machines.
write_start_script() {
  _wss_name="$1"
  _wss_display="$2"
  _wss_type="$3"
  _wss_host_kind="$4"
  _wss_path_sh="$VM_DIR/start-${_wss_name}.sh"
  _wss_path_ps1="$VM_DIR/start-${_wss_name}.ps1"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] write start helper scripts: %s, %s\n' "$_wss_path_sh" "$_wss_path_ps1"
    return 0
  fi

  case "$_wss_host_kind" in
    darwin-tart)
      cat >"$_wss_path_sh" <<EOF
#!/usr/bin/env sh
set -eu
tart run "$_wss_name"
EOF
      cat >"$_wss_path_ps1" <<EOF
# start-$_wss_name.ps1 — Start VM '$_wss_name' on macOS via Tart.
& tart run '$_wss_name'
EOF
      ;;
    darwin-utm)
      cat >"$_wss_path_sh" <<EOF
#!/usr/bin/env sh
set -eu
if [ -x '/Applications/UTM.app/Contents/MacOS/utmctl' ]; then
  '/Applications/UTM.app/Contents/MacOS/utmctl' start "$_wss_name" || {
    printf 'vm-setup: utmctl start failed for %s; opening bundle instead\n' "$_wss_name" >&2
    open "$VM_DIR/$_wss_name.utm"
  }
else
  open "$VM_DIR/$_wss_name.utm"
fi
EOF
      cat >"$_wss_path_ps1" <<EOF
# start-$_wss_name.ps1 — Start VM '$_wss_name' on macOS via UTM.
if (Test-Path '/Applications/UTM.app/Contents/MacOS/utmctl') {
  & '/Applications/UTM.app/Contents/MacOS/utmctl' start '$_wss_name'
  if (\$LASTEXITCODE -ne 0) {
    Write-Warning "vm-setup: utmctl start failed for $_wss_name; opening bundle instead"
    Start-Process -FilePath open -ArgumentList '$VM_DIR/$_wss_name.utm' | Out-Null
  }
} else {
  Start-Process -FilePath open -ArgumentList '$VM_DIR/$_wss_name.utm' | Out-Null
}
EOF
      ;;
    nixos-libvirt)
      cat >"$_wss_path_sh" <<EOF
#!/usr/bin/env sh
set -eu
if ! virsh start "$_wss_name" >/dev/null; then
  printf 'vm-setup: virsh start failed (or VM already running): %s\n' "$_wss_name" >&2
fi
if command -v virt-viewer >/dev/null 2>&1; then
  exec virt-viewer --connect qemu:///system "$_wss_name"
fi
printf 'vm-setup: VM started: %s\n' "$_wss_name"
printf 'vm-setup: install virt-viewer to open a console automatically\n'
EOF
      cat >"$_wss_path_ps1" <<EOF
# start-$_wss_name.ps1 — Start VM '$_wss_name' with libvirt.
& virsh start '$_wss_name' | Out-Null
if (\$LASTEXITCODE -ne 0) {
  Write-Warning "vm-setup: virsh start failed (or VM already running): $_wss_name"
}
if (Get-Command virt-viewer -ErrorAction SilentlyContinue) {
  & virt-viewer --connect qemu:///system '$_wss_name'
} else {
  Write-Host "vm-setup: VM started: $_wss_name"
  Write-Host 'vm-setup: install virt-viewer to open a console automatically'
}
EOF
      ;;
    *)
      printf 'vm-setup: unknown start-script host kind: %s\n' "$_wss_host_kind" >&2
      return 1
      ;;
  esac

  chmod 755 "$_wss_path_sh"
  chmod 755 "$_wss_path_ps1"
  printf 'vm-setup: wrote start helper scripts: %s, %s\n' "$_wss_path_sh" "$_wss_path_ps1"
}

# write_configure_script NAME TYPE
# Args:
#   $1 — VM machine name (manifest .name)
#   $2 — VM type (macOS/NixOS/Windows/...)
# Writes a host-side helper script that prints the guest-side converge command.
write_configure_script() {
  _wcs_name="$1"
  _wcs_type="$2"
  _wcs_path_sh="$VM_DIR/configure-${_wcs_name}.sh"
  _wcs_path_ps1="$VM_DIR/configure-${_wcs_name}.ps1"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] write configure helper scripts: %s, %s\n' "$_wcs_path_sh" "$_wcs_path_ps1"
    return 0
  fi

  case "$_wcs_type" in
    NixOS)
      _wcs_cmd="sudo nixos-rebuild switch --flake \"\$HOME/dev/nucleus/src#NixOS\""
      ;;
    Windows)
      _wcs_cmd='.\src\hosts\Windows\apply.ps1'
      ;;
    macOS)
      _wcs_cmd="\$HOME/dev/nucleus/scripts/bootstrap.sh apply"
      ;;
    *)
      _wcs_cmd='No guest converge command is defined for this VM type.'
      ;;
  esac

  cat >"$_wcs_path_sh" <<EOF
#!/usr/bin/env sh
set -eu
printf 'Guest configuration is not automatic. Run inside the guest:\n\n'
printf '%s\n' '$_wcs_cmd'
EOF

  cat >"$_wcs_path_ps1" <<EOF
# configure-$_wcs_name.ps1 — Show guest converge command for '$_wcs_name'.
Write-Host 'Guest configuration is not automatic. Run inside the guest:'
Write-Host ''
Write-Host '$_wcs_cmd'
EOF

  chmod 755 "$_wcs_path_sh"
  chmod 755 "$_wcs_path_ps1"
  printf 'vm-setup: wrote configure helper scripts: %s, %s\n' "$_wcs_path_sh" "$_wcs_path_ps1"
}

# ---------------------------------------------------------------------------
# Phase 1 — Build images (if absent)
# ---------------------------------------------------------------------------

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

# build_nixos_image NAME
#   Builds the NixOS guest image via nixos-generators.  On macOS this
#   requires an aarch64-linux builder; enable nix.linux-builder.enable in the
#   macOS host config so the Nix daemon delegates Linux derivations to the
#   Virtualization.framework-backed builder VM created by nix-darwin.
#   Most derivations are fetched from the binary cache; hostname-specific ones
#   (e.g. etc-hostname) are configuration-specific and cannot be cached.
build_nixos_image() {
  _name="$1"
  _out="$IMAGES_DIR/${_name}.qcow2"

  if [ -f "$_out" ]; then
    printf 'vm-setup: NixOS image already built (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  _guest_nix="$VMS_DIR/nixos/guest.nix"
  if [ ! -f "$_guest_nix" ]; then
    printf 'vm-setup: nixos guest config not found: %s\n' "$_guest_nix" >&2
    return 1
  fi

  printf 'vm-setup: building NixOS image (system=%s, format=%s)...\n' \
    "$_nixos_system" "$_nixos_format"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] nix run github:nix-community/nixos-generators -- --format %s --system %s --configuration %s -o <tmpdir>\n' \
      "$_nixos_format" "$_nixos_system" "$_guest_nix"
    return 0
  fi

  _tmpdir="$(mktemp -d)"
  _out_link="$_tmpdir/result"
  nix run github:nix-community/nixos-generators -- \
    --format "$_nixos_format" \
    --system "$_nixos_system" \
    --configuration "$_guest_nix" \
    -o "$_out_link"

  # nixos-generators' -o flag expects a non-existent symlink path, not an
  # already-created directory. Use a child path inside our temp dir so the link
  # can be created atomically, then resolve either a direct symlink-to-file or a
  # symlinked directory containing the final QCOW2 image.
  _img="$(readlink "$_out_link" 2>/dev/null || true)"
  if [ -z "$_img" ] || [ ! -f "$_img" ]; then
    _img="$(find -L "$_out_link" -maxdepth 2 -name '*.qcow2' -print -quit 2>/dev/null)"
  fi
  if [ -z "$_img" ] || [ ! -e "$_img" ]; then
    printf 'vm-setup: nixos-generators produced no .qcow2 via %s\n' "$_out_link" >&2
    rm -rf "$_tmpdir"
    return 1
  fi
  # -L follows symlinks so we copy the actual disk image bytes.
  cp -L "$_img" "$_out"
  rm -rf "$_tmpdir"
  printf 'vm-setup: NixOS image ready: %s\n' "$_out"
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
  _mido_edition="${2:-Pro}"

  _mido_vendor_script="$REPO_ROOT/vendor/qvm-create-windows-qube/windows/isos/mido.sh"
  _mido_script="${NUCLEUS_MIDO_SCRIPT:-$_mido_vendor_script}"
  if [ ! -f "$_mido_script" ]; then
    printf 'vm-setup: mido.sh not found; run: git submodule update --init vendor/qvm-create-windows-qube\n' >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'vm-setup: curl not found; required for Mido ISO download\n' >&2
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

  printf 'vm-setup: downloading Windows 11 ISO via Mido (media=%s)...\n' "$_mido_media"

  # Keep vendor submodules immutable by patching a temporary copy only.
  # This preserves a clean submodule tree while allowing fast compatibility
  # updates when Microsoft changes download-link HTML structures.
  _mido_patch_file="${NUCLEUS_MIDO_PATCH_FILE:-$REPO_ROOT/vms/windows/patches/mido-iso-link.patch}"
  _mido_script_tmp=''
  _mido_exec_script="$_mido_script"
  if [ -f "$_mido_patch_file" ]; then
    if command -v patch >/dev/null 2>&1; then
      _mido_script_tmp="$(mktemp -d)"
      _mido_exec_script="$_mido_script_tmp/mido.sh"
      cp "$_mido_script" "$_mido_exec_script"
      chmod 755 "$_mido_exec_script"
      if patch -s "$_mido_exec_script" "$_mido_patch_file" >/dev/null 2>&1; then
        printf 'vm-setup: applied runtime Mido patch: %s\n' "$_mido_patch_file"
      elif patch -s -R --dry-run "$_mido_exec_script" "$_mido_patch_file" >/dev/null 2>&1; then
        printf 'vm-setup: runtime Mido patch already present in source script; continuing\n'
      else
        printf 'vm-setup: runtime Mido patch failed to apply; update %s for current vendor mido.sh before retrying\n' "$_mido_patch_file" >&2
        rm -rf "$_mido_script_tmp"
        _mido_script_tmp=''
        return 1
      fi
    else
      printf 'vm-setup: patch command is required for Mido runtime patching; install patch and retry\n' >&2
      return 1
    fi
  else
    printf 'vm-setup: warning: runtime Mido patch file not found (%s); continuing with vendor script\n' "$_mido_patch_file" >&2
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
    PATH="${_mido_tmp}:${_mido_dir}:${PATH}" sh "$_mido_exec_script" "$_mido_media"
  ) || _mido_status=$?

  # Exit code 4 means verification failed but the ISO was downloaded as
  # .iso.UNVERIFIED (common for newer ISOs not yet in Mido's checksum list).
  # Accept the file and proceed; the caller can verify manually if desired.
  # Source: Mido exit codes in the ending_summary function of mido.sh
  if [ "$_mido_status" -ne 0 ] && [ "$_mido_status" -ne 4 ]; then
    printf 'vm-setup: Mido exited with code %s\n' "$_mido_status" >&2
    rm -rf "$_mido_tmp"
    rm -rf "$_mido_script_tmp"
    return 1
  fi

  _mido_iso="$(find "$_mido_tmp" -maxdepth 1 \( -name '*.iso' -o -name '*.iso.UNVERIFIED' \) -print -quit 2>/dev/null)"
  if [ -z "$_mido_iso" ]; then
    printf 'vm-setup: Mido: no ISO found in temp dir after download\n' >&2
    rm -rf "$_mido_tmp"
    rm -rf "$_mido_script_tmp"
    return 1
  fi

  mv "$_mido_iso" "$_mido_cached"
  rm -rf "$_mido_tmp"
  rm -rf "$_mido_script_tmp"
  printf 'vm-setup: Windows ISO downloaded: %s\n' "$_mido_cached"
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
  _fido_edition="${2:-Pro}"

  _fido_script="$REPO_ROOT/vendor/Fido/Fido.ps1"
  if [ ! -f "$_fido_script" ]; then
    printf 'vm-setup: Fido.ps1 not found; run: git submodule update --init vendor/Fido\n' >&2
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    printf 'vm-setup: pwsh not found; cannot use Fido for ISO auto-download\n'
    return 1
  fi

  printf 'vm-setup: downloading Windows 11 ISO via Fido (edition=%s)...\n' "$_fido_edition"
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
    printf 'vm-setup: Fido exited with code %s\n' "$_fido_status" >&2
    rm -rf "$_fido_tmp"
    return 1
  fi

  # Use find rather than ls to safely handle any filename; Fido downloads one
  # ISO so sort-by-time is unnecessary.
  _fido_iso="$(find "$_fido_tmp" -maxdepth 1 -name '*.iso' | head -1)"
  if [ -z "$_fido_iso" ]; then
    printf 'vm-setup: Fido: no ISO found in temp dir after download\n' >&2
    rm -rf "$_fido_tmp"
    return 1
  fi

  mv "$_fido_iso" "$_fido_cached"
  rm -rf "$_fido_tmp"
  printf 'vm-setup: Windows ISO downloaded: %s\n' "$_fido_cached"
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
  _fido_edition="${2:-Pro}"

  _fido_script="$REPO_ROOT/vendor/Fido/Fido.ps1"
  if [ ! -f "$_fido_script" ]; then
    printf 'vm-setup: Fido.ps1 not found; run: git submodule update --init vendor/Fido\n' >&2
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    printf 'vm-setup: pwsh not found; cannot use Fido URL fallback\n' >&2
    return 1
  fi

  if ! command -v perl >/dev/null 2>&1; then
    printf 'vm-setup: perl not found; cannot patch temporary Fido script for non-Windows URL fallback\n' >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'vm-setup: curl not found; required for Fido URL fallback download\n' >&2
    return 1
  fi

  case "$(printf '%s' "$_fido_edition" | tr '[:upper:]' '[:lower:]')" in
    *enterprise*) _fido_ed_query='Enterprise' ;;
    *) _fido_ed_query='Home/Pro/Edu' ;;
  esac

  printf 'vm-setup: resolving Windows 11 ISO URL via Fido fallback (edition=%s)...\n' "$_fido_ed_query"

  _fido_tmp="$(mktemp -d)"
  _fido_exec="$_fido_tmp/Fido.ps1"
  _fido_output_file="$_fido_tmp/fido-url.out"
  cp "$_fido_script" "$_fido_exec"

  # Fido intentionally blocks non-Windows at runtime; patch only the temp copy.
  # This keeps vendor sources immutable while still allowing CLI URL resolution.
  _fido_patch_status=0
  perl -0pi -e 's/if \(\$winver -le 6\.1\) \{/if (\$false) {/g' "$_fido_exec" || _fido_patch_status=$?
  if [ "$_fido_patch_status" -ne 0 ]; then
    printf 'vm-setup: failed to patch temporary Fido script for non-Windows fallback (exit %s)\n' "$_fido_patch_status" >&2
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
      printf 'vm-setup: Microsoft blocked automated ISO URL resolution (code 715-123130); retry later or use --windows-iso PATH\n' >&2
    fi
    printf 'vm-setup: Fido URL resolver exited with code %s\n' "$_fido_status" >&2
    rm -rf "$_fido_tmp"
    return 1
  fi

  _fido_url="$(grep -Eo 'https://[^[:space:]]+\.iso[^[:space:]]*' "$_fido_output_file" | tail -1)"
  if [ -z "$_fido_url" ]; then
    if grep -q '715-123130' "$_fido_output_file"; then
      printf 'vm-setup: Microsoft blocked automated ISO URL resolution (code 715-123130); retry later or use --windows-iso PATH\n' >&2
    fi
    printf 'vm-setup: Fido URL resolver returned no ISO URL\n' >&2
    rm -rf "$_fido_tmp"
    return 1
  fi

  printf 'vm-setup: downloading Windows ISO from resolved URL...\n'
  _fido_dl_status=0
  curl -fL -o "$_fido_cached" "$_fido_url" || _fido_dl_status=$?
  if [ "$_fido_dl_status" -ne 0 ]; then
    printf 'vm-setup: Fido URL fallback download failed (exit %s); removing partial file\n' "$_fido_dl_status" >&2
    rm -f "$_fido_cached"
    rm -rf "$_fido_tmp"
    return 1
  fi

  rm -rf "$_fido_tmp"
  printf 'vm-setup: Windows ISO downloaded via Fido URL fallback: %s\n' "$_fido_cached"
  return 0
}

# build_windows_image NAME DISK_GIB
#   Builds the Windows 11 guest image using Packer and the Autounattend.xml
#   answer file at vms/windows/Autounattend.xml.
build_windows_image() {
  _name="$1"
  _disk_gib="$2"
  _edition="${3:-Pro}"
  _out="$IMAGES_DIR/${_name}.qcow2"

  if [ -f "$_out" ]; then
    printf 'vm-setup: Windows image already built (delete to rebuild): %s\n' "$_out"
    return 0
  fi

  # Resolve the installer ISO: use --windows-iso if provided, otherwise try the
  # windowsIsoUrl field from VMs.json as a download source.
  _iso="$windows_iso"
  if [ -z "$_iso" ]; then
    printf 'vm-setup: Windows ISO fallback order: cached installer -> windowsIsoUrl -> downloader (%s mode)\n' "$windows_iso_source"
  fi

  # Resolve from cache first when --windows-iso is omitted.
  if [ -z "$_iso" ]; then
    _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
    if [ -f "$_cached_iso" ]; then
      printf 'vm-setup: using cached Windows installer: %s\n' "$_cached_iso"
      _iso="$_cached_iso"
    fi
  fi

  # Resolve via windowsIsoUrl next when allowed by source mode.
  if [ -z "$_iso" ] && [ "$windows_iso_source" != "mido" ]; then
    _iso_url="$(jq -r ".VMs[] | select(.name == \"$_name\") | .windowsIsoUrl // empty" "$MANIFEST")"
    if [ -n "$_iso_url" ]; then
      _cached_iso="$IMAGES_DIR/${_name}-installer.iso"
      printf 'vm-setup: downloading Windows installer from windowsIsoUrl...\n'
      if [ "$dry_run" = false ]; then
        if run_with_backoff 'windowsIsoUrl download' curl -fL -o "$_cached_iso" "$_iso_url"; then
          _iso="$_cached_iso"
          printf 'vm-setup: Windows installer downloaded: %s\n' "$_cached_iso"
        else
          printf 'vm-setup: windowsIsoUrl download failed; remove %s and retry\n' "$_cached_iso" >&2
          rm -f "$_cached_iso"
          return 1
        fi
      else
        printf 'vm-setup: [dry-run] curl -fL -o %s %s\n' "$_cached_iso" "$_iso_url"
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
          printf 'vm-setup: windows-iso-source=url selected and no cached/windowsIsoUrl installer was resolved\n' >&2
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
                printf 'vm-setup: Fido URL fallback failed on %s; trying Mido as secondary fallback\n' "$_host_uname" >&2
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
          printf 'vm-setup: [dry-run] windows-iso-source=url selected; no downloader fallback will run\n'
          ;;
        mido)
          printf 'vm-setup: [dry-run] would call vendor/qvm-create-windows-qube/windows/isos/mido.sh (with runtime patch copy)\n'
          ;;
        auto)
          printf 'vm-setup: [dry-run] non-Windows hosts: Fido URL resolver then Mido; Windows hosts: Mido then Fido\n'
          ;;
      esac
    fi
  fi

  if [ -z "$_iso" ]; then
    printf 'vm-setup: --windows-iso PATH is required for Windows 11 builds\n' >&2
    printf 'vm-setup: alternatively add "windowsIsoUrl": "<url>" to the VMs.json windows entry\n' >&2
    printf 'vm-setup: download from: https://www.microsoft.com/software-download/windows11\n' >&2
    return 1
  fi

  if [ ! -f "$_iso" ]; then
    printf 'vm-setup: Windows ISO not found: %s\n' "$_iso" >&2
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    printf 'vm-setup: packer not found; install via nixpkgs (pkgs.packer is in baseSharedPackages)\n' >&2
    return 1
  fi

  _packer_dir="$VMS_DIR/windows"
  _tmp_out="$IMAGES_DIR/${_name}-build"
  _winrm_timeout='3h'
  if [ "$accelerator" = 'tcg' ]; then
    # WHY: x86_64 Windows setup under software emulation can take much longer
    # than hardware-accelerated paths.  On Apple Silicon (arm64 host emulating
    # x86_64 guest) QEMU tcg typically runs at 2-5% of native speed, meaning
    # Windows PE load + installation + OOBE + FirstLogonCommands can take
    # 10-30 real hours.  Use a very generous timeout that covers even the
    # slowest realistic tcg speed.
    _winrm_timeout='72h'
  fi

  printf 'vm-setup: building Windows 11 image (disk=%s GiB, accelerator=%s)...\n' \
    "$_disk_gib" "$accelerator"
  _display_backend=''
  if [ "$windows_headless" = 'false' ]; then
    _display_help="$(qemu-system-x86_64 -display help || true)"
    for _display_candidate in cocoa gtk sdl spice-app curses; do
      if printf '%s\n' "$_display_help" | grep -qx "$_display_candidate"; then
        _display_backend="$_display_candidate"
        break
      fi
    done
    if [ -z "$_display_backend" ]; then
      printf 'vm-setup: no supported QEMU display backend found for headful debugging; available backends:\n%s\n' "$_display_help" >&2
      return 1
    fi
    printf 'vm-setup: debug mode enabled; running Windows Packer build headful (headless=false)\n'
    printf 'vm-setup: using QEMU display backend for debug run: %s\n' "$_display_backend"
  fi

  # WHY: BIOS installs may stall on the short "Press any key" prompt. Prefer
  # EFI-first attempts (no key spam) when host firmware files are available,
  # then fall back to BIOS strategies for broader compatibility.
  _efi_code=''
  _efi_vars=''
  _qemu_share=''
  _qemu_bin="$(command -v qemu-system-x86_64 2>/dev/null || true)"
  if [ -n "$_qemu_bin" ]; then
    _qemu_resolved="$_qemu_bin"
    _qemu_link_hops=0
    while [ "$_qemu_link_hops" -lt 8 ]; do
      _qemu_next="$(readlink "$_qemu_resolved" 2>/dev/null || true)"
      [ -n "$_qemu_next" ] || break
      _qemu_resolved="$_qemu_next"
      _qemu_link_hops=$((_qemu_link_hops + 1))
    done
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
    _build_attempts='bios spacebar 8h
bios alpha 8h
bios legacy 72h'
  else
    _build_attempts='bios none 30m
bios spacebar 2h
bios alpha 2h
bios legacy 3h'
  fi

  if [ -n "$_efi_code" ] && [ -n "$_efi_vars" ]; then
    _build_attempts="efi none 4h
$_build_attempts"
    printf 'vm-setup: EFI firmware detected; enabling EFI-first attempt (%s, %s)\n' "$_efi_code" "$_efi_vars"
  else
    printf 'vm-setup: EFI firmware not detected; using BIOS-only build attempts\n'
  fi

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] remove stale temporary output directory (if present): %s\n' "$_tmp_out"
    while IFS=' ' read -r _firmware_mode _boot_strategy _attempt_timeout; do
      [ -n "$_firmware_mode" ] || continue
      if [ "$_firmware_mode" = 'efi' ]; then
        if [ "$windows_headless" = 'false' ]; then
          printf 'vm-setup: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var firmware_mode=%s -var boot_strategy=%s -var winrm_timeout=%s -var headless=%s -var display_backend=%s -var efi_firmware_code=%s -var efi_firmware_vars=%s -var disk_size=%sG -var output_directory=%s .\n' \
            "$_packer_dir" "$_iso" "$accelerator" "$_firmware_mode" "$_boot_strategy" "$_attempt_timeout" "$windows_headless" "$_display_backend" "$_efi_code" "$_efi_vars" "$_disk_gib" "$_tmp_out"
        else
          printf 'vm-setup: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var firmware_mode=%s -var boot_strategy=%s -var winrm_timeout=%s -var headless=%s -var efi_firmware_code=%s -var efi_firmware_vars=%s -var disk_size=%sG -var output_directory=%s .\n' \
            "$_packer_dir" "$_iso" "$accelerator" "$_firmware_mode" "$_boot_strategy" "$_attempt_timeout" "$windows_headless" "$_efi_code" "$_efi_vars" "$_disk_gib" "$_tmp_out"
        fi
      else
        if [ "$windows_headless" = 'false' ]; then
          printf 'vm-setup: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var firmware_mode=%s -var boot_strategy=%s -var winrm_timeout=%s -var headless=%s -var display_backend=%s -var disk_size=%sG -var output_directory=%s .\n' \
            "$_packer_dir" "$_iso" "$accelerator" "$_firmware_mode" "$_boot_strategy" "$_attempt_timeout" "$windows_headless" "$_display_backend" "$_disk_gib" "$_tmp_out"
        else
          printf 'vm-setup: [dry-run] cd %s && packer build -var windows_iso=%s -var accelerator=%s -var firmware_mode=%s -var boot_strategy=%s -var winrm_timeout=%s -var headless=%s -var disk_size=%sG -var output_directory=%s .\n' \
            "$_packer_dir" "$_iso" "$accelerator" "$_firmware_mode" "$_boot_strategy" "$_attempt_timeout" "$windows_headless" "$_disk_gib" "$_tmp_out"
        fi
      fi
    done <<EOF
$_build_attempts
EOF
    return 0
  fi

  _packer_init_status=0
  (
    cd "$_packer_dir"
    packer init .
  ) || _packer_init_status=$?
  if [ "$_packer_init_status" -ne 0 ]; then
    printf 'vm-setup: Packer init for Windows VM "%s" failed (exit %s)\n' "$_name" "$_packer_init_status" >&2
    return "$_packer_init_status"
  fi

  _packer_status=1
  _built_tmpdir=''
  while IFS=' ' read -r _firmware_mode _boot_strategy _attempt_timeout; do
    [ -n "$_firmware_mode" ] || continue

    printf 'vm-setup: Windows Packer attempt using firmware_mode=%s boot_strategy=%s (winrm_timeout=%s)...\n' \
      "$_firmware_mode" "$_boot_strategy" "$_attempt_timeout"

    # WHY: Packer qemu builder requires a non-existent output_directory.
    # Use a fresh temp tree per attempt so a failed try cannot poison the next
    # firmware/boot-strategy combination.
    _attempt_tmpdir="$(mktemp -d "${IMAGES_DIR}/.${_name}.${_firmware_mode}.${_boot_strategy}.XXXXXX")"
    _tmp_out="$_attempt_tmpdir/output"

    _attempt_status=0
    if [ "$_firmware_mode" = 'efi' ]; then
      (
        cd "$_packer_dir"
        packer build \
          -var "windows_iso=$_iso" \
          -var "accelerator=$accelerator" \
          -var "firmware_mode=$_firmware_mode" \
          -var "boot_strategy=$_boot_strategy" \
          -var "winrm_timeout=$_attempt_timeout" \
          -var "headless=$windows_headless" \
          ${_display_backend:+-var "display_backend=$_display_backend"} \
          -var "efi_firmware_code=$_efi_code" \
          -var "efi_firmware_vars=$_efi_vars" \
          -var "disk_size=${_disk_gib}G" \
          -var "output_directory=$_tmp_out" \
          .
      ) || _attempt_status=$?
    else
      (
        cd "$_packer_dir"
        packer build \
          -var "windows_iso=$_iso" \
          -var "accelerator=$accelerator" \
          -var "firmware_mode=$_firmware_mode" \
          -var "boot_strategy=$_boot_strategy" \
          -var "winrm_timeout=$_attempt_timeout" \
          -var "headless=$windows_headless" \
          ${_display_backend:+-var "display_backend=$_display_backend"} \
          -var "disk_size=${_disk_gib}G" \
          -var "output_directory=$_tmp_out" \
          .
      ) || _attempt_status=$?
    fi

    if [ "$_attempt_status" -eq 0 ]; then
      _packer_status=0
      _built_tmpdir="$_attempt_tmpdir"
      break
    fi

    printf 'vm-setup: Windows Packer attempt failed for firmware_mode=%s boot_strategy=%s (exit %s); trying next strategy\n' \
      "$_firmware_mode" "$_boot_strategy" "$_attempt_status" >&2
    _packer_status="$_attempt_status"
    rm -rf "$_attempt_tmpdir"
  done <<EOF
$_build_attempts
EOF

  if [ "$_packer_status" -ne 0 ]; then
    printf 'vm-setup: Packer build for Windows VM "%s" failed (exit %s)\n' "$_name" "$_packer_status" >&2
    return "$_packer_status"
  fi
  _built="$_built_tmpdir/output/windows.qcow2"
  if [ ! -f "$_built" ]; then
    printf 'vm-setup: Packer did not produce %s\n' "$_built" >&2
    rm -rf "$_built_tmpdir"
    return 1
  fi

  mv "$_built" "$_out"
  rm -rf "$_built_tmpdir"
  printf 'vm-setup: Windows 11 image ready: %s\n' "$_out"
}

# build_macos_image NAME DISK_GIB RAM_MIB CPUS MACOS_VERSION
#   Builds the macOS guest VM using the Packer Tart plugin.  Requires tart
#   and packer to be installed; only runs on Darwin hosts (Tart uses Apple
#   Virtualization.framework which is not available on other platforms).
#   The resulting VM is stored in ~/virtual machines/.tart/vms/<name>/ (via
#   the ~/.tart symlink created by ensure_tart_vm_dir).
#   Source: https://github.com/cirruslabs/packer-plugin-tart
build_macos_image() {
  _name="$1"
  _disk_gib="$2"
  _ram_mib="$3"
  _cpus="$4"
  _macos_version="${5:-tahoe}"

  # Tart requires Apple Virtualization.framework — macOS host only.
  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'vm-setup: macOS guest build requires a macOS host (Tart uses Virtualization.framework); skipping\n'
    return 0
  fi

  if ! command -v tart >/dev/null 2>&1; then
    printf 'vm-setup: tart not found; install with: brew install cirruslabs/cli/tart\n' >&2
    return 1
  fi

  if ! command -v packer >/dev/null 2>&1; then
    printf 'vm-setup: packer not found; install via nixpkgs (pkgs.packer)\n' >&2
    return 1
  fi

  # Check if tart VM already exists.
  if tart list 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$_name"; then
    printf 'vm-setup: tart VM "%s" already exists (delete to rebuild: tart delete %s)\n' "$_name" "$_name"
    return 0
  fi

  _packer_dir="$VMS_DIR/macos"
  # Round MiB to nearest GiB for Tart (which accepts integer GiB only).
  # Uses (n + 512) / 1024 for round-half-up in integer arithmetic.
  _mem_gib="$(( (_ram_mib + 512) / 1024 ))"

  printf 'vm-setup: building macOS %s VM via Packer Tart (disk=%s GiB, mem=%s GiB, cpus=%s)...\n' \
    "$_macos_version" "$_disk_gib" "$_mem_gib" "$_cpus"

  if [ "$dry_run" = true ]; then
    printf 'vm-setup: [dry-run] cd %s && packer build -var vm_name=%s -var macos_version=%s -var disk_size_gib=%s -var memory_gib=%s -var cpus=%s .\n' \
      "$_packer_dir" "$_name" "$_macos_version" "$_disk_gib" "$_mem_gib" "$_cpus"
    return 0
  fi

  _packer_status=0
  (
    cd "$_packer_dir"
    packer init .
    packer build \
      -var "vm_name=$_name" \
      -var "macos_version=$_macos_version" \
      -var "disk_size_gib=$_disk_gib" \
      -var "memory_gib=$_mem_gib" \
      -var "cpus=$_cpus" \
      .
  ) || _packer_status=$?

  if [ "$_packer_status" -ne 0 ]; then
    printf 'vm-setup: Packer build for macOS VM "%s" failed (exit %s)\n' "$_name" "$_packer_status" >&2
    return "$_packer_status"
  fi
  printf 'vm-setup: macOS VM "%s" built and registered in tart\n' "$_name"
}

build_images() {
  _count="$(jq '.VMs | length' "$MANIFEST")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _vm_name="$(jq -r ".VMs[$_i].name" "$MANIFEST")"
    _vm_type="$(jq -r ".VMs[$_i].type" "$MANIFEST")"
    _vm_disk_bytes="$(jq -r ".VMs[$_i].diskBytes" "$MANIFEST")"
    # Convert SI bytes to nearest binary GiB for hypervisor tools.
    # Uses (n + 2^29) / 2^30 for round-half-up in POSIX integer arithmetic.
    _vm_disk_gib="$(( (_vm_disk_bytes + 536870912) / 1073741824 ))"

    if should_include "$_vm_type"; then
      case "$_vm_type" in
        NixOS)
          # WHY: best-effort — a prerequisite-missing or build failure for one
          # VM type must not abort builds for the remaining VMs; the build
          # function prints a specific error before returning non-zero.
          build_nixos_image "$_vm_name" \
            || printf 'vm-setup: NixOS image build skipped for "%s" (prerequisite missing or build failed; see above)\n' "$_vm_name" >&2
          ;;
        Windows)
          _vm_edition="$(jq -r ".VMs[$_i].windowsEdition // \"Pro\"" "$MANIFEST")"
          # WHY: best-effort — see NixOS branch above.
          build_windows_image "$_vm_name" "$_vm_disk_gib" "$_vm_edition" \
            || printf 'vm-setup: Windows image build skipped for "%s" (prerequisite missing or build failed; see above)\n' "$_vm_name" >&2
          ;;
        macOS)
          _vm_macos_ver="$(jq -r ".VMs[$_i].macOSVersion // \"tahoe\"" "$MANIFEST")"
          _vm_ram_bytes="$(jq -r ".VMs[$_i].ramBytes" "$MANIFEST")"
          # Convert SI bytes to nearest binary MiB for hypervisor tools.
          # Uses (n + 2^19) / 2^20 for round-half-up in POSIX integer arithmetic.
          _vm_ram_mib="$(( (_vm_ram_bytes + 524288) / 1048576 ))"
          _vm_cpus="$(jq -r ".VMs[$_i].cpus" "$MANIFEST")"
          # WHY: best-effort — see NixOS branch above.
          build_macos_image "$_vm_name" "$_vm_disk_gib" "$_vm_ram_mib" "$_vm_cpus" "$_vm_macos_ver" \
            || printf 'vm-setup: macOS image build skipped for "%s" (prerequisite missing or build failed; see above)\n' "$_vm_name" >&2
          ;;
        *)
          printf 'vm-setup: skipping build for "%s" (unsupported type: %s)\n' \
            "$_vm_name" "$_vm_type"
          ;;
      esac
    fi

    _i=$((_i + 1))
  done
}

# cleanup_vm_directory_artifacts
#   Removes obsolete helper artifacts from ~/virtual machines now that converge
#   guidance is centralized in ~/virtual machines/README.md.
cleanup_vm_directory_artifacts() {
  _cls_count="$(jq '.VMs | length' "$MANIFEST")"
  _cls_i=0
  while [ "$_cls_i" -lt "$_cls_count" ]; do
    _cls_name="$(jq -r ".VMs[$_cls_i].name" "$MANIFEST")"
    _cls_display="$(jq -r ".VMs[$_cls_i].display" "$MANIFEST")"
    for _cls_legacy in \
      "$VM_DIR/Start-${_cls_display}.sh" \
      "$VM_DIR/Start-${_cls_display}.ps1" \
      "$VM_DIR/${_cls_name}-configure.sh" \
      "$VM_DIR/${_cls_name}-configure.ps1"
    do
      if [ -f "$_cls_legacy" ]; then
        rm -f "$_cls_legacy"
        printf 'vm-setup: removed legacy helper script: %s\n' "$_cls_legacy"
      fi
    done
    _cls_i=$((_cls_i + 1))
  done

  _cls_legacy_dir="$HOME/.local/share/nucleus/vms/configure"
  if [ -d "$_cls_legacy_dir" ]; then
    rm -rf "$_cls_legacy_dir"
    printf 'vm-setup: removed legacy helper directory: %s\n' "$_cls_legacy_dir"
  fi

  if [ -f "$VM_DIR/.DS_Store" ]; then
    rm -f "$VM_DIR/.DS_Store"
    printf 'vm-setup: removed Finder metadata file: %s\n' "$VM_DIR/.DS_Store"
  fi
}

# ---------------------------------------------------------------------------
# macOS / Tart (macOS guests)
# ---------------------------------------------------------------------------

# setup_tart_vms — Phase 2 provisioning checks for macOS-type VM guests.
#   The Packer Tart build already registered the VM in tart's store; this
#   function validates registration and reports runtime entry points.
#   Source: https://github.com/cirruslabs/tart
setup_tart_vms() {
  if ! command -v tart >/dev/null 2>&1; then
    printf 'vm-setup: tart not found; skipping macOS VM start-script generation\n'
    return
  fi

  vm_count=$(jq '.VMs | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".VMs[$i].name" "$MANIFEST")
    vm_type=$(jq -r ".VMs[$i].type" "$MANIFEST")

    if [ "$vm_type" != "macOS" ] || ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    # Verify the tart VM was created in phase 1.
    if ! tart list 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$vm_name"; then
      printf 'vm-setup: WARNING — tart VM "%s" not found; Packer build may have failed or was skipped\n' "$vm_name" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      printf 'vm-setup: tart VM ready: %s (start with: tart run %s)\n' "$vm_name" "$vm_name"
      write_start_script "$vm_name" "$vm_name" "$vm_type" 'darwin-tart'
      write_configure_script "$vm_name" "$vm_type"
    else
      printf 'vm-setup: [dry-run] verify tart VM registration: %s\n' "$vm_name"
    fi

    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# macOS / UTM (NixOS and Windows guests on macOS host)
# ---------------------------------------------------------------------------

setup_utm_vms() {
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

  if [ ! -d /Applications/UTM.app ]; then
    printf 'vm-setup: UTM not found at /Applications/UTM.app; skipping macOS VM provisioning\n'
    return
  fi

  vm_count=$(jq '.VMs | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".VMs[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".VMs[$i].display" "$MANIFEST")
    vm_type=$(jq -r ".VMs[$i].type" "$MANIFEST")

    if ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    # macOS guests are provisioned via tart (setup_tart_vms), not UTM.
    if [ "$vm_type" = "macOS" ]; then
      printf 'vm-setup: macOS guest "%s" stays on Tart runtime; skipping UTM bundle provisioning for this VM\n' "$vm_name"
      i=$((i + 1))
      continue
    fi

    bundle="$VM_DIR/${vm_name}.utm"
    data_dir="$bundle/Data"
    disk_file="$data_dir/disk-main.qcow2"
    config_plist="$bundle/config.plist"
    bundle_exists=false

    printf 'vm-setup: configuring UTM VM "%s"...\n' "$vm_display"

    if [ -d "$bundle" ]; then
      bundle_exists=true
      printf 'vm-setup: UTM bundle already exists: %s; refreshing config.plist\n' "$bundle"
    fi

    # Use the Nix-generated UTM config.plist written to ~/.local/share/nucleus/
    # at Home Manager activation time (run nucleus-apply first).
    _plist_template="${HOME}/.local/share/nucleus/vms/${vm_name}-config.plist"
    if [ ! -f "$_plist_template" ]; then
      printf 'vm-setup: WARNING \u2014 UTM config template not found at %s; apply the macOS config first\n' "$_plist_template" >&2
      i=$((i + 1))
      continue
    fi
    # Detect stale templates from older schema/value generations and fail fast
    # with a concrete action instead of copying a known-invalid plist.
    if grep -qE 'virtio-ramfb-gl|<key>DirectorySharing</key>|<key>ReadOnlySharing</key>|<key>SharedDirectories</key>' "$_plist_template"; then
      printf 'vm-setup: WARNING — stale UTM template detected at %s; run home-manager switch (or nucleus apply) before vm-setup\n' "$_plist_template" >&2
      i=$((i + 1))
      continue
    fi
    # Require a pre-built image only when the bundle does not already have a
    # disk. Existing bundles can refresh config.plist in-place.
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    if [ ! -f "$disk_file" ] && [ ! -f "$_prebuilt" ]; then
      _build_tmp="$IMAGES_DIR/${vm_name}-build"
      if [ -d "$_build_tmp" ]; then
        printf 'vm-setup: WARNING — image not ready for %s; build appears in progress at %s\n' "$vm_name" "$_build_tmp" >&2
      else
        printf 'vm-setup: WARNING — image not found: %s; build failed or type not supported\n' "$_prebuilt" >&2
      fi
      i=$((i + 1))
      continue
    fi

    write_start_script "$vm_name" "$vm_display" "$vm_type" 'darwin-utm'
    write_configure_script "$vm_name" "$vm_type"

    if [ "$dry_run" = false ]; then
      mkdir -p "$data_dir"
      if [ ! -f "$disk_file" ]; then
        cp "$_prebuilt" "$disk_file"
        printf 'vm-setup: copied pre-built disk image: %s\n' "$disk_file"
      else
        printf 'vm-setup: preserving existing disk image: %s\n' "$disk_file"
      fi
      cp "$_plist_template" "$config_plist"
      # Nix store files are read-only (mode 0444).  Make the bundle-local copy
      # writable so UTM can update the plist after import if needed.
      chmod +w "$config_plist"
      if [ "$bundle_exists" = true ]; then
        printf 'vm-setup: refreshed UTM bundle config: %s\n' "$bundle"
      else
        printf 'vm-setup: UTM bundle created: %s\n' "$bundle"
      fi
      if ! "$UTMCTL" list | awk 'NR > 1 { print $3 }' | grep -qxF "$vm_name"; then
        printf 'vm-setup: importing UTM bundle via AppleScript: %s\n' "$bundle"
        osascript -e "tell application \"UTM\" to import new virtual machine from POSIX file \"$bundle\""
      else
        printf 'vm-setup: UTM VM already registered: %s\n' "$vm_name"
      fi
    else
      printf 'vm-setup: [dry-run] create UTM bundle %s from %s\n' "$bundle" "$_plist_template"
    fi

    i=$((i + 1))
  done

  printf 'vm-setup: macOS VM setup complete\n'
}

# ---------------------------------------------------------------------------
# NixOS / libvirt
# ---------------------------------------------------------------------------

setup_libvirt_vms() {
  if ! command -v virsh >/dev/null 2>&1; then
    printf 'vm-setup: virsh not found in PATH; libvirtd may not be enabled yet\n'
    printf 'vm-setup: apply the NixOS configuration first so vms.nix activates libvirtd\n'
    return
  fi

  # Ensure the libvirt default network is started so VMs can reach the host.
  if virsh net-list --all 2>/dev/null | grep -q "default"; then
    if ! virsh net-list 2>/dev/null | grep -q "default.*active"; then
      printf 'vm-setup: starting libvirt default network...\n'
      run_cmd virsh net-start default || true
      run_cmd virsh net-autostart default || true
    fi
  fi

  vm_count=$(jq '.VMs | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$vm_count" ]; do
    vm_name=$(jq -r ".VMs[$i].name" "$MANIFEST")
    vm_display=$(jq -r ".VMs[$i].display" "$MANIFEST")
    vm_type=$(jq -r ".VMs[$i].type" "$MANIFEST")

    if ! should_include "$vm_type"; then
      i=$((i + 1))
      continue
    fi

    disk_path="$VM_DIR/${vm_name}.qcow2"

    printf 'vm-setup: configuring libvirt VM "%s"...\n' "$vm_display"

    # Require a pre-built image (built in phase 1).
    _prebuilt="$IMAGES_DIR/${vm_name}.qcow2"
    if [ ! -f "$_prebuilt" ]; then
      printf 'vm-setup: WARNING \u2014 image not found: %s; skipping "%s"\n' "$_prebuilt" "$vm_name" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      mkdir -p "$VM_DIR"
      if [ ! -f "$disk_path" ]; then
        cp "$_prebuilt" "$disk_path"
        printf 'vm-setup: disk image placed: %s\n' "$disk_path"
      else
        printf 'vm-setup: disk already exists: %s\n' "$disk_path"
      fi
    else
      printf 'vm-setup: [dry-run] copy %s to %s\n' "$_prebuilt" "$disk_path"
    fi

    # Define/update the libvirt domain from the Nix-generated XML (idempotent).
    # The file is installed at apply time by environment.etc in vms.nix.
    _xml_file="/etc/nucleus/vms/${vm_name}-domain.xml"
    if [ ! -f "$_xml_file" ]; then
      printf 'vm-setup: WARNING — domain XML not found at %s; apply the NixOS config first\n' "$_xml_file" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" = false ]; then
      if virsh define "$_xml_file"; then
        printf 'vm-setup: VM "%s" defined/updated in libvirt\n' "$vm_name"
        write_start_script "$vm_name" "$vm_display" "$vm_type" 'nixos-libvirt'
        write_configure_script "$vm_name" "$vm_type"
      else
        printf 'vm-setup: WARNING — virsh define failed for "%s"; check libvirtd status\n' "$vm_name" >&2
      fi
    else
      printf 'vm-setup: [dry-run] virsh define %s\n' "$_xml_file"
    fi

    i=$((i + 1))
  done

  printf 'vm-setup: NixOS VM setup complete; use virt-manager to start VMs\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf 'vm-setup: reading manifest from %s\n' "$MANIFEST"
if [ "$dry_run" = true ]; then
  printf 'vm-setup: dry-run mode — no changes will be made\n'
fi

if [ "$dry_run" = false ]; then
  mkdir -p "$VM_DIR"
  mkdir -p "$IMAGES_DIR"
  write_vm_directory_readme

  if [ "$(uname -s)" = "Darwin" ]; then
    ensure_tart_vm_dir
    ensure_utm_default_vm_location
  fi
fi

printf 'vm-setup: phase 1 \u2014 building images...\n'
build_images

printf 'vm-setup: phase 2 \u2014 provisioning VMs...\n'
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
      printf 'vm-setup: standalone Linux detected; use QEMU/KVM directly:\n'
      printf 'vm-setup:   qemu-img create -f qcow2 ~/virtual\ machines/<name>.qcow2 <size>G\n'
      printf 'vm-setup:   qemu-system-x86_64 -m <ram> -smp <cpu> -hda ~/virtual\ machines/<name>.qcow2 ...\n'
    fi
    ;;
  *)
    printf 'vm-setup: unsupported OS "%s"; nothing to do\n' "$_os"
    ;;
esac

if [ "$dry_run" = false ]; then
  cleanup_vm_directory_artifacts
fi

printf 'vm-setup: done\n'
