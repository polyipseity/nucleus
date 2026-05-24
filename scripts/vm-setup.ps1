# scripts/vm-setup.ps1 — Build VM images (if needed) and provision VMs on Windows.
#
# Combines the former nucleus-VM-build and nucleus-vm-setup into one command.
# Phase 1 builds pre-built QCOW2 images via Packer (if absent).
# Phase 2 provisions QEMU start scripts and copies disk images.
#
# Thin wrapper that delegates to
# src\hosts\windows\modules\system\Invoke-VMSetup.ps1.
#
# Usage:
#   .\scripts\vm-setup.ps1 [-WindowsIso PATH] [-NixosOnly] [-WindowsOnly]
#                          [-Accelerator TYPE] [-DryRun]
#
# Or via the shell alias:
#   nucleus-vm-setup [same parameters]
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
[CmdletBinding()]
param(
    # Path to Windows 11 ISO (required for Windows 11 guest builds).
    # Download from: https://www.microsoft.com/software-download/windows11
    [string]$WindowsIso = '',

    # Build and provision only the NixOS guest.
    [switch]$NixosOnly,

    # Build and provision only the Windows 11 guest.
    [switch]$WindowsOnly,

    # QEMU accelerator for image builds (default: tcg).
    # Use whpx for Windows HyperVisor Platform acceleration.
    [string]$Accelerator = 'tcg',

    # Print planned actions without executing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') |
    Select-Object -ExpandProperty Path

$module = Join-Path $repoRoot 'src\hosts\windows\modules\system\Invoke-VMSetup.ps1'
if (-not (Test-Path $module)) {
    Write-Warning "vm-setup: module not found at $module"
    exit 1
}

. $module

$invokeArgs = @{ RepoRoot = $repoRoot; DryRun = $DryRun }
if ($WindowsIso)  { $invokeArgs['WindowsIso']  = $WindowsIso }
if ($NixosOnly)   { $invokeArgs['NixosOnly']   = $true }
if ($WindowsOnly) { $invokeArgs['WindowsOnly'] = $true }
if ($Accelerator) { $invokeArgs['Accelerator'] = $Accelerator }

Invoke-VMSetup @invokeArgs
