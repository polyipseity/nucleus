# Daily system log rotation for Windows scheduled tasks and manual use.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $env:NUCLEUS_REPO_ROOT
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  Write-Error 'log-gc-system: NUCLEUS_REPO_ROOT not set'
}

$moduleDir = Join-Path -Path $repoRoot -ChildPath 'src\hosts\Windows\modules'
$schemaPath = Join-Path -Path $repoRoot -ChildPath 'src\modules\services.schema.json'
. (Join-Path -Path $moduleDir -ChildPath 'Invoke-LogManagement.ps1')

try {
  $schemaContent = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
  $loggingDefaults = $schemaContent.definitions.loggingEntry.properties
} catch {
  Write-Warning "log-gc-system: failed to parse services.schema.json; using hardcoded defaults — $($_.Exception.Message)"
  $loggingDefaults = $null
}

$logMaxSize = if ($loggingDefaults.maxSize.default) { [int]$loggingDefaults.maxSize.default } else { 10000000 } # bytes
$logMaxFiles = if ($loggingDefaults.maxFiles.default) { [int]$loggingDefaults.maxFiles.default } else { 4 }
$logCompress = if ($null -ne $loggingDefaults.compress.default) { [bool]$loggingDefaults.compress.default } else { $true }

Invoke-LogRotation -Path (Get-NucleusSystemLogDir) -MaxSize $logMaxSize -MaxFiles $logMaxFiles -Compress $logCompress
