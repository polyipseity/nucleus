# scripts/vm-setup.ps1 — Build VM images (if needed) and provision VMs on Windows.
#
# Combines the former nucleus-VM-build and nucleus-vm-setup into one command.
# Phase 1 builds pre-built QCOW2 images via Packer (if absent).
# Phase 2 provisions QEMU start scripts and copies disk images.
#
# Thin wrapper that delegates to
# src\hosts\Windows\modules\system\Invoke-VMSetup.ps1.
#
# Usage:
#   .\scripts\vm-setup.ps1 [-WindowsIso PATH] [-WindowsIsoSource Auto|Url|Fido] [-NixosOnly] [-WindowsOnly]
#                          [-Accelerator TYPE] [-DryRun]
#
# Or via the shell alias:
#   nucleus-vm-setup [same parameters]
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
[CmdletBinding()]
param(
    # Path to Windows 11 ISO. Optional when windowsIsoUrl is set in VMs.json.
    # Download from: https://www.microsoft.com/software-download/windows11
    [string]$WindowsIso = '',

    # Build and provision only the NixOS guest.
    [switch]$NixosOnly,

    # Build and provision only the Windows 11 guest.
    [switch]$WindowsOnly,

    # Windows installer ISO resolution strategy.
    # Auto: windowsIsoUrl cache/download first, then Fido fallback.
    # Url:  use only -WindowsIso or windowsIsoUrl (no downloader fallback).
    # Fido: use only local cache/Fido when -WindowsIso is omitted.
    [ValidateSet('Auto', 'Url', 'Fido')]
    [string]$WindowsIsoSource = 'Auto',

    # Retry attempts for Windows ISO network downloads (default: 0).
    [int]$WindowsIsoRetries = 0,

    # QEMU accelerator for image builds (default: tcg, auto-upgraded to whpx
    # when Windows Hypervisor Platform is detected).
    [string]$Accelerator = 'tcg',

    # Print planned actions without executing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') |
    Select-Object -ExpandProperty Path

$module = Join-Path $repoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
if (-not (Test-Path $module)) {
    Write-Warning "vm-setup: module not found at $module"
    exit 1
}

. $module

$invokeArgs = @{ RepoRoot = $repoRoot; DryRun = $DryRun }
if ($WindowsIso)  { $invokeArgs['WindowsIso']  = $WindowsIso }
if ($NixosOnly)   { $invokeArgs['NixosOnly']   = $true }
if ($WindowsOnly) { $invokeArgs['WindowsOnly'] = $true }
if ($WindowsIsoSource) { $invokeArgs['WindowsIsoSource'] = $WindowsIsoSource }
if ($PSBoundParameters.ContainsKey('WindowsIsoRetries')) { $invokeArgs['WindowsIsoRetries'] = $WindowsIsoRetries }
if ($Accelerator) { $invokeArgs['Accelerator'] = $Accelerator }

Invoke-VMSetup @invokeArgs
