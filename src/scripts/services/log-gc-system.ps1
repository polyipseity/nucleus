# Daily system log rotation for Windows scheduled tasks and manual use.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force

$repoRoot = $env:NUCLEUS_REPO_ROOT
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  Write-NucleusError -CommandName log-gc-system 'NUCLEUS_REPO_ROOT not set'
}

$moduleDir = Join-Path -Path $repoRoot -ChildPath 'src\platforms\Windows\modules'
$schemaPath = Join-Path -Path $repoRoot -ChildPath 'src\modules\services.schema.json'
. (Join-Path -Path $moduleDir -ChildPath 'Invoke-LogManagement.ps1')

try {
  $schemaContent = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
  $loggingDefaults = $schemaContent.definitions.loggingEntry.properties
} catch {
  Write-NucleusWarning -CommandName log-gc-system "failed to parse services.schema.json; using hardcoded defaults — $($_.Exception.Message)"
  $loggingDefaults = $null
}

$logMaxSize = if ($loggingDefaults.maxSize.default) { [int]$loggingDefaults.maxSize.default } else { 10000000 } # bytes
$logMaxFiles = if ($loggingDefaults.maxFiles.default) { [int]$loggingDefaults.maxFiles.default } else { 4 }
$logCompress = if ($null -ne $loggingDefaults.compress.default) { [bool]$loggingDefaults.compress.default } else { $true }

$logExpiry = if ($env:NUCLEUS_GC_EXPIRY) { $env:NUCLEUS_GC_EXPIRY } else { '7d' }

Invoke-LogRotation -Path (Get-NucleusSystemLogDir) -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
Invoke-LogExpiry -Path (Get-NucleusSystemLogDir) -Expiry $logExpiry
