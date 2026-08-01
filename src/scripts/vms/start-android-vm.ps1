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

  Expects disk images under ~\virtual machines\images\:
    - android-system.qcow2   (system partition, vda)
    - android-userdata.qcow2 (userdata partition, vdb)
    - android-gsi.img        (optional GSI system image, vdc)

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
$imagesDir   = Join-Path $env:USERPROFILE 'virtual machines\images'
$firmwareDir = if (Get-Command 'qemu-img.exe' -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: qemu-img.exe is optional -- fallback to qemu dir
                 Split-Path (Get-Command 'qemu-img.exe').Source -Parent
               } else {
                 Split-Path $qemu.Source -Parent
               }

$diskSystem   = Join-Path $imagesDir 'android-system.qcow2'
$diskUserdata = Join-Path $imagesDir 'android-userdata.qcow2'
$diskGsi      = Join-Path $imagesDir 'android-gsi.img'
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
  '-smp', '4',
  '-m', '4096'
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

# Network (ADB port forwarding).
$qemuArgs.AddRange(@(
  '-netdev', 'user,id=net0,hostfwd=tcp::5555-:5555,hostfwd=tcp::5554-:5554',
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
Write-Output "  CPUs: 4  RAM: 4096 MB  Accel: tcg"
Write-Output "  ADB:   localhost:5555 -> guest:5555 (emulator) / localhost:5554 -> guest:5554 (console)"

Start-Process -FilePath $qemu.Source -ArgumentList $qemuArgs -Wait -NoNewWindow
