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
#   .\scripts\vm-setup.ps1 [-WindowsIso PATH] [-WindowsIsoSource Auto|Url|Fido]
#                          [-Accelerator TYPE] [-Headful] [-NoHeadful] [-DryRun]
#
# Or via the shell alias:
#   nucleus-vm-setup [same parameters]
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
[CmdletBinding()]
param(
    # Path to Windows 11 ISO. Optional when windowsIsoUrl is set in VMs.json (default: '').
    # Download from: https://www.microsoft.com/software-download/windows11
    [string]$WindowsIso = $(if ($env:NUCLEUS_VM_WINDOWS_ISO) { $env:NUCLEUS_VM_WINDOWS_ISO } else { '' }),

    # Windows installer ISO resolution strategy.
    # Auto: windowsIsoUrl cache/download first, then Fido fallback.
    # Url:  use only -WindowsIso or windowsIsoUrl (no downloader fallback).
    # Fido: use only local cache/Fido when -WindowsIso is omitted (default: Auto).
    [ValidateSet('Auto', 'Url', 'Fido')]
    [string]$WindowsIsoSource = $(if ($env:NUCLEUS_VM_WINDOWS_ISO_SOURCE) { $env:NUCLEUS_VM_WINDOWS_ISO_SOURCE } else { 'Auto' }),

    # Retry attempts for Windows ISO network downloads (default: 0).
    [int]$WindowsIsoRetries = $(if ($env:NUCLEUS_VM_WINDOWS_ISO_RETRIES) { [int]$env:NUCLEUS_VM_WINDOWS_ISO_RETRIES } else { 0 }),

    # QEMU accelerator for image builds. Defaults to tcg (always works on
    # Windows; WHPX auto-detected and upgraded when available). POSIX
    # defaults to auto (hvf on macOS, kvm on Linux, tcg otherwise) —
    # intentional platform-appropriate defaults.
    [string]$Accelerator = $(if ($env:NUCLEUS_VM_ACCELERATOR) { $env:NUCLEUS_VM_ACCELERATOR } else { 'tcg' }),

    # Run guest image builds headful (headless=false) for interactive
    # debugging of installer/SSH readiness issues (default: $false).
    [switch]$DebugHeadful = { $env:NUCLEUS_VM_DEBUG_HEADFUL -eq 'true' }.Invoke(),

    # Print planned actions without executing (default: $false).
    [switch]$DryRun = $(if ($env:NUCLEUS_DRY_RUN -eq 'true') { $true } else { $false }),

    [Alias("h")]
    [switch]$Headful = { $env:NUCLEUS_VM_HEADFUL -eq 'true' }.Invoke(),

    # Run Windows image builds headless (default: $true).
    [switch]$NoHeadful
)

$ErrorActionPreference = 'Stop'

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

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
if ($WindowsIsoSource) { $invokeArgs['WindowsIsoSource'] = $WindowsIsoSource }
if ($PSBoundParameters.ContainsKey('WindowsIsoRetries')) { $invokeArgs['WindowsIsoRetries'] = $WindowsIsoRetries }
if ($Accelerator) { $invokeArgs['Accelerator'] = $Accelerator }
if ($Headful) { $invokeArgs['Headful'] = $true }
if ($NoHeadful) { $invokeArgs['Headful'] = $false }

Invoke-VMSetup @invokeArgs
