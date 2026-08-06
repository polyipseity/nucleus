<#
.SYNOPSIS
  Start the Android virtual machine via QEMU on Windows.

.DESCRIPTION
  Launches aarch64 Android (GSI-based) VM under QEMU with TCG acceleration
  (no WHPX for cross-arch guests), UEFI firmware, GPU/display, USB tablet
  input, and ADB port forwarding.

  Shared canonical file (embedded-content policy): consumed by vm.sh
  (windows-qemu start script generation) and Start-AndroidVM.ps1 (thin
  wrapper). Keep single-source — do not embed a copy elsewhere.

  Expects disk images with filenames from the manifest Android group
  (rendered by vm.sh via __ANDROID_SYSTEM_IMAGE__ / __ANDROID_USERDATA_IMAGE__ /
  __ANDROID_GSI_IMAGE__ tokens):
    - <systemImage>   (system partition, vda)   under ~\virtual machines\images\
    - <userdataImage> (userdata partition, vdb) under ~\virtual machines\data\
    - <gsiImage>      (optional GSI system image, vdc) under ~\virtual machines\images\

  Firmware path defaults to the edk2-aarch64 UEFI image bundled with QEMU's
  standard installation layout (Scoop/manual).

.NOTES
  Requires qemu-system-aarch64 in PATH (Scoop package: qemu).
  Run this script directly to launch the Android VM.
#>

#Requires -Version 7.4

$ErrorActionPreference = 'Stop'

# --- Locate QEMU binary ---
$qemu = Get-Command 'qemu-system-aarch64.exe' -ErrorAction Stop

# --- Paths ---
# System/GSI images live under images/ (read-only payload); the writable
# userdata disk lives under data/ (canonical disk-model layout: every VM's
# writable disk is data/<id>.qcow2).
$imagesDir   = Join-Path $env:USERPROFILE 'virtual machines\images'
$dataDir     = Join-Path $env:USERPROFILE 'virtual machines\data'
$firmwareDir = if (Get-Command 'qemu-img.exe' -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: qemu-img.exe is optional -- fallback to qemu dir
                 Split-Path (Get-Command 'qemu-img.exe').Source -Parent
               } else {
                 Split-Path $qemu.Source -Parent
               }

$diskSystem   = Join-Path $imagesDir '__ANDROID_SYSTEM_IMAGE__'
$diskUserdata = Join-Path $dataDir '__ANDROID_USERDATA_IMAGE__'
$diskGsi      = Join-Path $imagesDir '__ANDROID_GSI_IMAGE__'
$uefiCode     = Join-Path $firmwareDir 'edk2-aarch64-code.fd'
$uefiVars     = Join-Path $firmwareDir 'edk2-arm-vars.fd'

# Validate required disks.
foreach ($d in @($diskSystem, $diskUserdata)) {
  if (-not (Test-Path -LiteralPath $d -PathType Leaf)) {
    Write-Error "Required disk image not found: $d"
    exit 1
  }
}

# --- Build QEMU arguments ---
$qemuArgs = [System.Collections.Generic.List[string]]::new()

# Machine and acceleration.
$qemuArgs.AddRange(@(
  '-machine', 'virt',
  '-accel', 'tcg'
))

# CPU and memory.
$qemuArgs.AddRange(@(
  '-cpu', 'max',
  '-smp', '__ANDROID_CPU_COUNT__',
  '-m', '__ANDROID_RAM_BYTES__'
))

# UEFI firmware.
$qemuArgs.AddRange(@(
  '-drive', "if=pflash,format=raw,readonly=on,file=$uefiCode",
  '-drive', "if=pflash,format=raw,file=$uefiVars"
))

# Disks.
$qemuArgs.AddRange(@(
  '-drive', "file=$diskSystem,format=qcow2,if=none,id=drive-system",
  '-device', 'virtio-blk-pci,drive=drive-system',
  '-drive', "file=$diskUserdata,format=qcow2,if=none,id=drive-userdata",
  '-device', 'virtio-blk-pci,drive=drive-userdata'
))

if (Test-Path -LiteralPath $diskGsi -PathType Leaf) {
  $qemuArgs.AddRange(@(
    '-drive', "file=$diskGsi,format=raw,if=none,id=drive-gsi",
    '-device', 'virtio-blk-pci,drive=drive-gsi'
  ))
}

# Network (port forwarding from manifest portForwards).
$qemuArgs.AddRange(@(
  '-netdev', 'user,id=net0,__HOSTFWDS__',
  '-device', 'virtio-net-pci,netdev=net0'
))

# Display and GPU.
$qemuArgs.AddRange(@(
  '-device', 'virtio-gpu-pci',
  '-display', 'gtk'
))

# Input (USB tablet for cursor).
$qemuArgs.AddRange(@(
  '-device', 'usb-tablet'
))

# USB controller (required for usb-tablet).
$qemuArgs.AddRange(@(
  '-device', 'qemu-xhci'
))

# Android boot flags.
$qemuArgs.AddRange(@(
  '-append', 'androidboot.hardware=android_x86_64 androidboot.selinux=permissive'
))

# --- Launch QEMU ---
Write-Output "Starting Android VM: $($qemu.Source)"
Write-Output "  CPUs: __ANDROID_CPU_COUNT__  RAM: __ANDROID_RAM_BYTES__  Accel: tcg"
Write-Output "  Port forwards: __HOSTFWDS__"

Start-Process -FilePath $qemu.Source -ArgumentList $qemuArgs -Wait -NoNewWindow
