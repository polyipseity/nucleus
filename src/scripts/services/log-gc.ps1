# Daily log rotation for Windows scheduled tasks and manual use.
#
# The system tree is root-owned, so the scheduled task runs it elevated; the
# user tree runs as the logged-on user. The operations belong to nucleus-logs;
# this wrapper only selects scope and runs the app in the system or user domain.

[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [ValidateSet('user', 'system')]
  [string]$Scope
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force

# WHY NUCLEUS_LOGS_BIN: one seam for the app entry point, so the scheduled-task
# wrapper and the tests resolve it the same way gc.ps1 does.
$logsBin = if ($env:NUCLEUS_LOGS_BIN) {
  $env:NUCLEUS_LOGS_BIN
} else {
  Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\logs.ps1'
}
if (-not (Test-Path -LiteralPath $logsBin -PathType Leaf)) {
  Write-NucleusError -CommandName log-gc "nucleus-logs entry point not found at '$logsBin'"
  exit 1
}

& (Get-Process -Id $PID).Path -NoProfile -NoLogo -File $logsBin -Action gc -Scope $Scope
if ($LASTEXITCODE -ne 0) {
  Write-NucleusError -CommandName log-gc "nucleus-logs gc failed with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}
