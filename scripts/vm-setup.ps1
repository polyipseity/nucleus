# vm-setup.ps1 — Windows wrapper for the VM provisioning module.
# Provisions and configures virtual machines declared in src/modules/vms.json
# using QEMU (installed via Scoop extras bucket) on Windows.
#
# Usage:
#   .\scripts\vm-setup.ps1 [-DryRun]
#
# Parameters:
#   -DryRun  Print planned actions without executing them.
#
# This wrapper follows the same pattern as scripts\AI-sync.ps1.
[CmdletBinding()]
param(
    # Print planned actions without modifying any state.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') |
    Select-Object -ExpandProperty Path
$modulePath = Join-Path $repoRoot 'src\hosts\windows\modules\system\Invoke-VMSetup.ps1'

if (-not (Test-Path $modulePath)) {
    Write-Information "vm-setup: module not found: $modulePath"
    exit 0
}

. $modulePath

$params = @{
    RepoRoot = $repoRoot
}
if ($DryRun) {
    $params['DryRun'] = $true
}

Invoke-VMSetup @params
