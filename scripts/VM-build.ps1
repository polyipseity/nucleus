# scripts/VM-build.ps1 — Windows entry point for nucleus-VM-build.
#
# Thin wrapper that locates the nucleus repository root and delegates to
# src\hosts\windows\modules\system\Invoke-VMBuild.ps1.
#
# Usage:
#   scripts\VM-build.ps1 [-WindowsIso PATH] [-NixosOnly] [-WindowsOnly]
#                        [-Accelerator TYPE] [-DryRun]
#
# Or via the shell alias:
#   nucleus-VM-build [same parameters]
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu

[CmdletBinding()]
param(
    [string]$WindowsIso = '',
    [switch]$NixosOnly,
    [switch]$WindowsOnly,
    [string]$Accelerator = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') |
    Select-Object -ExpandProperty Path

$module = Join-Path $repoRoot 'src\hosts\windows\modules\system\Invoke-VMBuild.ps1'
if (-not (Test-Path $module)) {
    Write-Warning "VM-build: module not found at $module"
    exit 1
}

. $module

$invokeArgs = @{ DryRun = $DryRun }
if ($WindowsIso)      { $invokeArgs['WindowsIso']  = $WindowsIso }
if ($NixosOnly)       { $invokeArgs['NixosOnly']   = $true }
if ($WindowsOnly)     { $invokeArgs['WindowsOnly'] = $true }
if ($Accelerator)     { $invokeArgs['Accelerator'] = $Accelerator }

Invoke-VMBuild @invokeArgs
