<#
.SYNOPSIS
  Start the Android virtual machine via QEMU on Windows.

.DESCRIPTION
  Thin wrapper — the canonical start logic lives in the shared file
  src/scripts/vms/start-android-vm.ps1 (embedded-content policy). vm.sh also
  renders start-<name>.ps1 from that same shared file; keep this wrapper thin
  so QEMU arguments stay single-source.

.NOTES
  Requires qemu-system-aarch64 in PATH (Scoop package: qemu).
  Run this script directly to launch the Android VM.
#>

#Requires -Version 7.4

$ErrorActionPreference = 'Stop'

# WHY: shared cross-platform content per embedded-content policy — delegate
# to the canonical script instead of duplicating the start logic here.
& (Join-Path $PSScriptRoot '..\..\..\..\scripts\vms\start-android-vm.ps1')
