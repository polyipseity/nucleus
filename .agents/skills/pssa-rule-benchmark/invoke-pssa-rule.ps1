<#
.SYNOPSIS
  Benchmark one PSScriptAnalyzer rule (one run) in an isolated pwsh process.
  Designed to be spawned by pssa-rule-benchmark.ps1.

.PARAMETER RuleName
  The exact rule name to benchmark (e.g. PSAvoidUsingCmdletAliases).

.PARAMETER SettingsFile
  Path to PSScriptAnalyzerSettings.psd1 (for Severity/ExcludeRules filtering).

.PARAMETER RepoRoot
  Repository root directory. Defaults to current working directory.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$RuleName,

  [Parameter(Mandatory)]
  [string]$SettingsFile,

  [string]$RepoRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location $RepoRoot

$sw = [System.Diagnostics.Stopwatch]::StartNew()

try {
  Import-Module PSScriptAnalyzer -ErrorAction Stop

  # Discover files
  $paths = @(git ls-files '*.ps1') | Where-Object { Test-Path $_ }
  $fileCount = $paths.Count

  if ($fileCount -eq 0) {
    $sw.Stop()
    $result = [PSCustomObject]@{
      RuleName    = $RuleName
      Severity    = $null
      ElapsedMs   = 0
      DiagCount   = 0
      FileCount   = 0
      Error       = $true
      ErrorMessage = 'no files found'
      Timestamp   = [DateTime]::UtcNow.ToString('o')
    }
    $result | ConvertTo-Json -Depth 3 -Compress
    exit 1
  }

  # Verify rule exists
  $rule = Get-ScriptAnalyzerRule -Name $RuleName
  if (-not $rule) {
    $sw.Stop()
    $result = [PSCustomObject]@{
      RuleName    = $RuleName
      Severity    = $null
      ElapsedMs   = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
      DiagCount   = 0
      FileCount   = $fileCount
      Error       = $true
      ErrorMessage = "rule '$RuleName' not found by Get-ScriptAnalyzerRule"
      Timestamp   = [DateTime]::UtcNow.ToString('o')
    }
    $result | ConvertTo-Json -Depth 3 -Compress
    exit 1
  }

  # Load base settings, then narrow to just this one rule
  $baseSettings = Import-PowerShellDataFile -Path $SettingsFile
  $settings = @{
    IncludeRules = [string[]]@($RuleName)
    Rules        = @{}
  }
  if ($baseSettings.ContainsKey('Severity')) {
    $settings.Severity = $baseSettings.Severity
  }

  # Run the analyzer for just this one rule
  $sw.Restart()
  $diags = $paths | Invoke-ScriptAnalyzer -Settings $settings 2>&1
  $sw.Stop()

  $diagCount = 0
  if ($diags -and $diags -is [array]) { $diagCount = @($diags).Count }

  $result = [PSCustomObject]@{
    RuleName    = $RuleName
    Severity    = $rule.Severity.ToString()
    ElapsedMs   = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    DiagCount   = $diagCount
    FileCount   = $fileCount
    Error       = $false
    ErrorMessage = $null
    Timestamp   = [DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 3 -Compress
  exit 0
}
catch {
  $sw.Stop()
  $result = [PSCustomObject]@{
    RuleName    = $RuleName
    Severity    = $null
    ElapsedMs   = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    DiagCount   = 0
    FileCount   = 0
    Error       = $true
    ErrorMessage = $_.Exception.Message
    Timestamp   = [DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 3 -Compress
  exit 1
}
finally {
  Pop-Location
}
