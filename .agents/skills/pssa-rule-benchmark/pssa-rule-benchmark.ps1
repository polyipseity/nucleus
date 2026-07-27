<#
.SYNOPSIS
  Benchmark each PSScriptAnalyzer rule independently.
  Uses a single pwsh session with Invoke-ScriptAnalyzer for each rule.
#>
[CmdletBinding()]
param(
  [string]$ResultsFile = (Join-Path $PSScriptRoot 'pssa-rule-benchmark-results.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settingsData = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1')
$enabledSeverities = [System.Collections.Generic.HashSet[string]]@($settingsData.Severity)
$excludedRules = [System.Collections.Generic.HashSet[string]]@($settingsData.ExcludeRules)

Import-Module PSScriptAnalyzer
if (Get-Module PSReadLine -ListAvailable) { Import-Module PSReadLine }

# --- Get all enabled rules ---
$allRules = Get-ScriptAnalyzerRule | Where-Object {
  $_.RuleName -notin $excludedRules -and $_.Severity -in $enabledSeverities
} | Sort-Object RuleName

$totalRules = $allRules.Count
Write-Output ('Enabled rules: {0}' -f $totalRules)

# --- Get file list once ---
$paths = @(git ls-files '*.ps1') | Where-Object { Test-Path $_ }
$fileCount = $paths.Count
Write-Output ('Files to analyze: {0}' -f $fileCount)

Write-Output ''
Write-Output '=== BENCHMARKING ==='

# --- Benchmark each rule ---
$results = @()
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt $allRules.Count; $i++) {
  $rule = $allRules[$i]
  $ruleName = $rule.RuleName
  $pct = [math]::Round(($i / $totalRules) * 100, 1)
  Write-Output ('[{0}/{1} ({2}%)] {3}' -f ($i + 1), $totalRules, $pct, $ruleName)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $diags = $paths | Invoke-ScriptAnalyzer -Settings @{
    IncludeRules = [string[]]@($ruleName)
    Rules = @{}
  } 2>&1
  $sw.Stop()

  $diagCount = 0
  if ($diags -and $diags -is [array]) { $diagCount = @($diags).Count }

  $elapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
  Write-Output ('  {0} ms, {1} diagnostics' -f $elapsedMs, $diagCount)

  $results += [PSCustomObject]@{
    RuleName  = $ruleName
    Severity  = $rule.Severity.ToString()
    ElapsedMs = $elapsedMs
    DiagCount = $diagCount
    FileCount = $fileCount
  }

  # Incremental save
  ($results | ConvertTo-Json -Depth 5) | Set-Content $ResultsFile
}

$totalSw.Stop()

Write-Output ''
Write-Output ('=== BENCHMARK COMPLETE === Total: {0}s' -f [math]::Round($totalSw.Elapsed.TotalSeconds, 1))
Write-Output ''

Write-Output '=== TOP 10 SLOWEST ==='
$results | Sort-Object ElapsedMs -Descending | Select-Object -First 10 |
  Format-Table RuleName, Severity, @{N='ElapsedMs';E={$_.ElapsedMs}}, DiagCount -AutoSize

Write-Output ''
Write-Output '=== BOTTOM 5 (fastest) ==='
$results | Sort-Object ElapsedMs | Select-Object -First 5 |
  Format-Table RuleName, Severity, @{N='ElapsedMs';E={$_.ElapsedMs}}, DiagCount -AutoSize

Write-Output ''
Write-Output ('Full results saved to: {0}' -f $ResultsFile)
