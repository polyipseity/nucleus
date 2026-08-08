# Daily user log rotation for Windows scheduled tasks and manual use.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $env:NUCLEUS_REPO_ROOT
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  Write-Error 'log-gc-user: NUCLEUS_REPO_ROOT not set'
}

$moduleDir = Join-Path -Path $repoRoot -ChildPath 'src\platforms\Windows\modules'
$schemaPath = Join-Path -Path $repoRoot -ChildPath 'src\modules\services.schema.json'
. (Join-Path -Path $moduleDir -ChildPath 'Invoke-LogManagement.ps1')

try {
  $schemaContent = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
  $loggingDefaults = $schemaContent.definitions.loggingEntry.properties
} catch {
  Write-Warning "log-gc-user: failed to parse services.schema.json; using hardcoded defaults — $($_.Exception.Message)"
  $loggingDefaults = $null
}

$logMaxSize = if ($loggingDefaults.maxSize.default) { [int]$loggingDefaults.maxSize.default } else { 10000000 } # bytes
$logMaxFiles = if ($loggingDefaults.maxFiles.default) { [int]$loggingDefaults.maxFiles.default } else { 4 }
$logCompress = if ($null -ne $loggingDefaults.compress.default) { [bool]$loggingDefaults.compress.default } else { $true }

$logExpiry = if ($env:NUCLEUS_GC_EXPIRY) { $env:NUCLEUS_GC_EXPIRY } else { '7d' }
$userLogDir = Get-NucleusLogDir

Invoke-LogRotation -Path $userLogDir -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
Invoke-LogExpiry -Path $userLogDir -Expiry $logExpiry
