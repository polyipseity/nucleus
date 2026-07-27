<#
.SYNOPSIS
  Benchmark each PSScriptAnalyzer rule independently using subprocess isolation.
  Runs each rule multiple times in random order, spawning a fresh pwsh process
  per invocation.

.DESCRIPTION
  Generates a task matrix of (rule x -Runs) tasks, randomizes the global order,
  and spawns each task as an independent pwsh -NoProfile subprocess. Results
  are aggregated per rule (mean, min, max, stddev, median) and saved as JSON.

.PARAMETER Runs
  Number of benchmark runs per rule. Default: 3.

.PARAMETER ResultsFile
  Path to write aggregated results JSON. Default: pssa-rule-benchmark-results.json
  in the skill directory.

.PARAMETER SkipExisting
  If set, skip rules that already have Runs results in the existing ResultsFile.
  Useful for resuming an interrupted benchmark.

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -Runs 5

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -Runs 3 -SkipExisting
#>
[CmdletBinding()]
param(
  [int]$Runs = 3,
  [string]$ResultsFile = (Join-Path $PSScriptRoot 'pssa-rule-benchmark-results.json'),
  [switch]$SkipExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
$settingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$subprocessPath = Join-Path $PSScriptRoot 'invoke-pssa-rule.ps1'
$repoRoot = (Get-Location).Path

if (-not (Test-Path $settingsPath)) { throw "Settings file not found: $settingsPath" }
if (-not (Test-Path $subprocessPath)) { throw "Subprocess script not found: $subprocessPath" }

# ---------------------------------------------------------------------------
# Read settings
# ---------------------------------------------------------------------------
$settingsData = Import-PowerShellDataFile $settingsPath
$enabledSeverities = [System.Collections.Generic.HashSet[string]]@($settingsData.Severity)
$excludedRules = [System.Collections.Generic.HashSet[string]]@($settingsData.ExcludeRules)

Import-Module PSScriptAnalyzer -ErrorAction Stop
$psVersion = $PSVersionTable.PSVersion
$psaModule = Get-Module PSScriptAnalyzer
$psaVersion = if ($psaModule) { $psaModule.Version } else { 'unknown' }

Write-Output "pwsh: $($psVersion.Major).$($psVersion.Minor).$($psVersion.Patch)"
Write-Output "PSScriptAnalyzer: $psaVersion"
Write-Output "Repository: $repoRoot"
Write-Output ""

# ---------------------------------------------------------------------------
# Get all enabled rules
# ---------------------------------------------------------------------------
$allRules = Get-ScriptAnalyzerRule | Where-Object {
  $_.RuleName -notin $excludedRules -and $_.Severity -in $enabledSeverities
} | Sort-Object RuleName

$totalRules = $allRules.Count
Write-Output "Enabled rules: $totalRules"

# ---------------------------------------------------------------------------
# Discover files for count display (subprocess discovers independently)
# ---------------------------------------------------------------------------
$paths = @(git ls-files '*.ps1') | Where-Object { Test-Path $_ }
$fileCount = $paths.Count
Write-Output "Files to analyze: $fileCount"

# ---------------------------------------------------------------------------
# Random seed
# ---------------------------------------------------------------------------
$seed = Get-Random
Write-Output "Random seed: $seed"
Write-Output ""

# ---------------------------------------------------------------------------
# Load existing results if SkipExisting
# ---------------------------------------------------------------------------
$skipRules = [System.Collections.Generic.HashSet[string]]::new()
if ($SkipExisting -and (Test-Path $ResultsFile)) {
  try {
    $existingData = Get-Content $ResultsFile -Raw | ConvertFrom-Json
    foreach ($entry in $existingData) {
      if ($entry.Runs -ge $Runs) {
        $null = $skipRules.Add($entry.RuleName)
        Write-Output "Skipping $($entry.RuleName) (already has $Runs runs)"
      }
    }
    Write-Output ""
  } catch {
    Write-Output "Warning: could not parse existing results file, will re-benchmark all rules"
    Write-Output ""
  }
}

# ---------------------------------------------------------------------------
# Generate task matrix
# ---------------------------------------------------------------------------
$tasks = [System.Collections.Generic.List[object]]::new()
foreach ($rule in $allRules) {
  if ($skipRules.Contains($rule.RuleName)) { continue }
  for ($r = 1; $r -le $Runs; $r++) {
    $tasks.Add([PSCustomObject]@{
      RuleName = $rule.RuleName
      Severity = $rule.Severity.ToString()
      RunIndex = $r
    })
  }
}

# Shuffle globally
$tasks = $tasks | Sort-Object { Get-Random }
$totalTasks = $tasks.Count
Write-Output "Total benchmark tasks: $totalTasks"
Write-Output ""
Write-Output '=== BENCHMARKING ==='

# ---------------------------------------------------------------------------
# Helper: build aggregated results from raw data
# ---------------------------------------------------------------------------
function Convert-RawResultsToAggregated {
  param([object[]]$RawResults)

  $grouped = $RawResults | Where-Object { -not $_.Error } | Group-Object RuleName

  $aggregated = $grouped | ForEach-Object {
    $ruleName = $_.Name
    $vals = $_.Group.ElapsedMs
    $diagVals = $_.Group.DiagCount
    $count = $vals.Count

    $mean = [math]::Round(($vals | Measure-Object -Average).Average, 1)
    $minElapsed = [math]::Round(($vals | Measure-Object -Minimum).Minimum, 1)
    $maxElapsed = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1)

    $sorted = $vals | Sort-Object
    $median = if ($count % 2 -eq 1) {
      [math]::Round($sorted[($count - 1) / 2], 1)
    } else {
      [math]::Round(($sorted[$count / 2 - 1] + $sorted[$count / 2]) / 2, 1)
    }

    $meanDiag = [math]::Round(($diagVals | Measure-Object -Average).Average, 1)

    $sqSum = 0.0
    foreach ($v in $vals) { $sqSum += ($v - $mean) * ($v - $mean) }
    $variance = if ($count -gt 1) { $sqSum / $count } else { 0.0 }
    $stddev = [math]::Round([math]::Sqrt($variance), 1)

    $first = $_.Group | Select-Object -First 1
    $rawData = $_.Group | ForEach-Object {
      @{
        Run       = $_.Run
        ElapsedMs = $_.ElapsedMs
        DiagCount = $_.DiagCount
        Timestamp = $_.Timestamp
      }
    }

    [PSCustomObject]@{
      RuleName      = $ruleName
      Severity      = $first.Severity
      FileCount     = $first.FileCount
      Runs          = $count
      MeanMs        = $mean
      MinMs         = $minElapsed
      MaxMs         = $maxElapsed
      StdDevMs      = $stddev
      MedianMs      = $median
      MeanDiagCount = $meanDiag
      RawData       = $rawData
    }
  }

  return @($aggregated)
}

# ---------------------------------------------------------------------------
# Benchmark: spawn subprocess per task
# ---------------------------------------------------------------------------
$rawResults = [System.Collections.Generic.List[object]]::new()
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$failedTasks = 0
$rawResultsFile = "$ResultsFile.raw"
$incrementalCounter = 0

for ($ti = 0; $ti -lt $totalTasks; $ti++) {
  $task = $tasks[$ti]
  $pct = [math]::Round(($ti / $totalTasks) * 100, 1)
  $ruleName = $task.RuleName
  $runIdx = $task.RunIndex

  Write-Output "[$($ti + 1)/$totalTasks ($pct%)] $ruleName (run $runIdx/$Runs)"

  # Spawn subprocess
  $psi = [System.Diagnostics.ProcessStartInfo]@{
    FileName               = $pwshPath
    Arguments              = "-NoProfile -File `"$subprocessPath`" -RuleName `"$ruleName`" -SettingsFile `"$settingsPath`""
    RedirectStandardOutput = $true
    RedirectStandardError  = $true
    UseShellExecute        = $false
    WorkingDirectory       = $repoRoot
    StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  }

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $exited = $proc.WaitForExit(600000)  # 600s timeout per subprocess
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result

  # Parse result
  $parsed = $null
  $isError = $false
  $errorMsg = $null
  $elapsedMs = 0.0
  $diagCount = 0
  $resultFileCount = 0

  if (-not $exited) {
    # Timeout
    $proc.Kill()
    $proc.WaitForExit(5000)
    $proc.Dispose()
    $isError = $true
    $errorMsg = 'subprocess timed out after 600s'
    Write-Output '  TIMEOUT (>600s)'
  } elseif (($exitCode = $proc.ExitCode) -ne 0) {
    # Non-zero exit — try to parse stdout as JSON for structured error
    try {
      $parsed = $stdout.Trim() | ConvertFrom-Json
      $isError = if ($null -ne $parsed.Error) { $parsed.Error } else { $true }
      $errorMsg = if ($parsed.ErrorMessage) { $parsed.ErrorMessage } else { "unknown error (exit code $exitCode)" }
      if ($parsed.ElapsedMs) { $elapsedMs = $parsed.ElapsedMs }
    } catch {
      $isError = $true
      $errorMsg = "subprocess exited with code $exitCode"
      if ($stdout.Trim()) { $errorMsg += ": $($stdout.Trim())" }
      if ($stderr.Trim()) { Write-Output "  STDERR: $($stderr.Trim())" }
    }
    Write-Output "  FAILED: $errorMsg"
  } else {
    # Success — parse JSON
    try {
      $parsed = $stdout.Trim() | ConvertFrom-Json
      if ($parsed.Error) {
        $isError = $true
        $errorMsg = $parsed.ErrorMessage
        Write-Output "  ERROR: $errorMsg"
      } else {
        $elapsedMs = $parsed.ElapsedMs
        $diagCount = $parsed.DiagCount
        $resultFileCount = $parsed.FileCount
        Write-Output "  $elapsedMs ms, $diagCount diagnostics"
      }
    } catch {
      $isError = $true
      $errorMsg = "JSON parse error: $($_.Exception.Message)"
      Write-Output "  JSON PARSE ERROR: $errorMsg"
      if ($stdout.Trim()) {
        $previewLen = [math]::Min(200, $stdout.Length)
        Write-Output "  RAW: $($stdout.Substring(0, $previewLen))"
      }
    }
  }

  if ($isError) { $failedTasks++ }

  $rawResults.Add([PSCustomObject]@{
    RuleName     = $ruleName
    Severity     = $task.Severity
    ElapsedMs    = if ($null -ne $parsed -and $null -ne $parsed.ElapsedMs) { $parsed.ElapsedMs } else { $elapsedMs }
    DiagCount    = if ($null -ne $parsed -and $null -ne $parsed.DiagCount) { $parsed.DiagCount } else { 0 }
    FileCount    = $resultFileCount
    Error        = $isError
    ErrorMessage = $errorMsg
    Timestamp    = if ($null -ne $parsed -and $parsed.Timestamp) { $parsed.Timestamp } else { [DateTime]::UtcNow.ToString('o') }
    Run          = $runIdx
  })

  # Incremental save every 10 tasks
  $incrementalCounter++
  if ($incrementalCounter % 10 -eq 0) {
    $rawResults.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $rawResultsFile
    $elapsed = [math]::Round($totalSw.Elapsed.TotalSeconds, 0)
    Write-Output "  [checkpoint saved: $incrementalCounter tasks in ${elapsed}s]"
  }
}

# Final raw save (catches remaining <10 tasks)
$rawResults.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $rawResultsFile

$totalSw.Stop()

# ---------------------------------------------------------------------------
# Final aggregation
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output ('=== BENCHMARKING DONE === Total wall-clock: {0}s' -f [math]::Round($totalSw.Elapsed.TotalSeconds, 1))
if ($failedTasks -gt 0) { Write-Output "Failed tasks: $failedTasks" }

$aggregated = Convert-RawResultsToAggregated -RawResults $rawResults.ToArray()

Write-Output ''
Write-Output '=== TOP 10 SLOWEST (by MeanMs) ==='
$aggregated | Sort-Object MeanMs -Descending | Select-Object -First 10 |
  Format-Table RuleName, Severity, MeanMs, MinMs, MaxMs, StdDevMs, MedianMs, MeanDiagCount -AutoSize

Write-Output ''
Write-Output '=== BOTTOM 5 (fastest) ==='
$aggregated | Sort-Object MeanMs | Select-Object -First 5 |
  Format-Table RuleName, Severity, MeanMs, MinMs, MaxMs, StdDevMs, MedianMs, MeanDiagCount -AutoSize

Write-Output ''
$aggregated | ConvertTo-Json -Depth 5 | Set-Content $ResultsFile
Write-Output "Full results saved to: $ResultsFile"
Remove-Item $rawResultsFile -ErrorAction SilentlyContinue
