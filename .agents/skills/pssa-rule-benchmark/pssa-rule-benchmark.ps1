<#
.SYNOPSIS
  Benchmark each PSScriptAnalyzer rule independently using subprocess isolation.
  Runs each rule multiple times in random order, spawning a fresh pwsh process
  per invocation.

.DESCRIPTION
  Generates a task matrix of (rule x -Runs) tasks, randomizes the global order,
  and spawns each task as an independent pwsh -NoProfile subprocess. Results
  are aggregated per rule (mean, min, max, stddev, median) and saved as JSON.
  A summary row always counts the rows recorded for it, including when a rule
  has a single row.

.PARAMETER Runs
  Number of benchmark runs per rule. Default: 3.

.PARAMETER ResultsFile
  Path to write aggregated results JSON. Default: pssa-rule-benchmark-results.json
  in the skill directory.

.PARAMETER SkipExisting
  If set, skip rules that already have Runs results in the existing ResultsFile.
  Useful for resuming an interrupted benchmark. Rules left out this way keep the
  rows already in the file, so the written file still describes every rule it
  holds.

.PARAMETER SelfTest
  Run the aggregation self-test instead of benchmarking: synthetic rows of one,
  two, and three samples, failed rows, and a resume merge. Exits 0 when every
  summary matches its recorded rows, 1 otherwise.

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -Runs 5

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -Runs 3 -SkipExisting

.EXAMPLE
  pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -SelfTest
#>
[CmdletBinding()]
param(
  [int]$Runs = 3,
  [string]$ResultsFile = (Join-Path $PSScriptRoot 'pssa-rule-benchmark-results.json'),
  [switch]$SkipExisting,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Runs -lt 1) { throw "-Runs must be at least 1 (got $Runs)." }

# ---------------------------------------------------------------------------
# Aggregation
#
# Under StrictMode '.Count' throws on a scalar, and a rule with one recorded row
# puts a bare number in its group instead of a one-element array, so every
# column is wrapped in '@()' before it is counted, sorted, or indexed.
# ---------------------------------------------------------------------------
function Convert-RawResultsToAggregated {
  param([object[]]$RawResults)

  $grouped = @($RawResults) | Where-Object { -not $_.Error } | Group-Object RuleName

  $aggregated = @($grouped | ForEach-Object {
    $ruleName = $_.Name
    $vals = @($_.Group.ElapsedMs)
    $diagVals = @($_.Group.DiagCount)
    $count = $vals.Count

    $mean = [math]::Round(($vals | Measure-Object -Average).Average, 1)
    $minElapsed = [math]::Round(($vals | Measure-Object -Minimum).Minimum, 1)
    $maxElapsed = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1)

    $sorted = @($vals | Sort-Object)
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
    $rawData = @($_.Group | ForEach-Object {
      @{
        Run       = $_.Run
        ElapsedMs = $_.ElapsedMs
        DiagCount = $_.DiagCount
        Timestamp = $_.Timestamp
      }
    })

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
  })

  return $aggregated
}

# The results file is a resume target, so it holds every rule it has recorded:
# rules left out of this run keep the rows already in the file.
function Merge-AggregatedResultSet {
  param([object[]]$NewResults, [object[]]$ExistingResults)

  $newRuleNames = @(@($NewResults).RuleName)
  $carriedOver = @(@($ExistingResults) | Where-Object { $_.RuleName -notin $newRuleNames })
  $merged = @($NewResults) + $carriedOver
  return $merged | Sort-Object RuleName
}

# ---------------------------------------------------------------------------
# Self-test: every summary row must describe exactly the rows recorded for it.
# One run per rule is what '-Runs 1' produces, and it is the case that used to
# abort aggregation outright.
# ---------------------------------------------------------------------------
function Invoke-AggregationSelfTest {
  $failures = [System.Collections.Generic.List[string]]::new()

  $makeRow = {
    param([string]$RuleName, [double]$ElapsedMs, [int]$Run, [bool]$IsError)
    [PSCustomObject]@{
      RuleName     = $RuleName
      Severity     = 'Warning'
      FileCount    = 1
      ElapsedMs    = $ElapsedMs
      DiagCount    = 0
      Error        = $IsError
      ErrorMessage = if ($IsError) { 'subprocess failed' } else { $null }
      Timestamp    = '2026-01-01T00:00:00.000000Z'
      Run          = $Run
    }
  }

  $assert = {
    param([string]$Label, [bool]$Condition, [string]$Actual)
    if (-not $Condition) { $failures.Add("$Label (got $Actual)") }
  }

  $singleRow = @(& $makeRow -RuleName 'Alpha' -ElapsedMs 500.0 -Run 1 -IsError $false)
  $single = @(Convert-RawResultsToAggregated -RawResults $singleRow)
  $assert.Invoke('one row: entry count', ($single.Count -eq 1), $single.Count)
  $assert.Invoke('one row: Runs', ($single[0].Runs -eq 1), $single[0].Runs)
  $assert.Invoke('one row: RawData length', (@($single[0].RawData).Count -eq 1), @($single[0].RawData).Count)
  $assert.Invoke('one row: MeanMs', ($single[0].MeanMs -eq 500.0), $single[0].MeanMs)
  $assert.Invoke('one row: MedianMs', ($single[0].MedianMs -eq 500.0), $single[0].MedianMs)
  $assert.Invoke('one row: MinMs/MaxMs', (($single[0].MinMs -eq 500.0) -and ($single[0].MaxMs -eq 500.0)), "$($single[0].MinMs)/$($single[0].MaxMs)")
  $assert.Invoke('one row: StdDevMs', ($single[0].StdDevMs -eq 0.0), $single[0].StdDevMs)

  $twoRules = @(
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 500.0 -Run 1 -IsError $false),
    (& $makeRow -RuleName 'Beta' -ElapsedMs 700.0 -Run 1 -IsError $false)
  )
  $twoRuleAgg = @(Convert-RawResultsToAggregated -RawResults $twoRules)
  $assert.Invoke('two rules, one row each: entry count', ($twoRuleAgg.Count -eq 2), $twoRuleAgg.Count)
  $assert.Invoke('two rules, one row each: Runs', (@($twoRuleAgg | Where-Object { $_.Runs -ne 1 }).Count -eq 0), @($twoRuleAgg | Where-Object { $_.Runs -ne 1 }).Count)

  $threeRows = @(
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 100.0 -Run 1 -IsError $false),
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 300.0 -Run 2 -IsError $false),
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 200.0 -Run 3 -IsError $false)
  )
  $three = @(Convert-RawResultsToAggregated -RawResults $threeRows)
  $assert.Invoke('three rows: Runs', ($three[0].Runs -eq 3), $three[0].Runs)
  $assert.Invoke('three rows: RawData length', (@($three[0].RawData).Count -eq 3), @($three[0].RawData).Count)
  $assert.Invoke('three rows: MeanMs', ($three[0].MeanMs -eq 200.0), $three[0].MeanMs)
  $assert.Invoke('three rows: MedianMs', ($three[0].MedianMs -eq 200.0), $three[0].MedianMs)

  $twoRows = @(
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 100.0 -Run 1 -IsError $false),
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 300.0 -Run 2 -IsError $false)
  )
  $two = @(Convert-RawResultsToAggregated -RawResults $twoRows)
  $assert.Invoke('two rows: MedianMs', ($two[0].MedianMs -eq 200.0), $two[0].MedianMs)

  $withFailure = @(
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 100.0 -Run 1 -IsError $false),
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 900.0 -Run 2 -IsError $true)
  )
  $mixed = @(Convert-RawResultsToAggregated -RawResults $withFailure)
  $assert.Invoke('failed row excluded from Runs', ($mixed[0].Runs -eq 1), $mixed[0].Runs)
  $assert.Invoke('failed row excluded from RawData', (@($mixed[0].RawData).Count -eq 1), @($mixed[0].RawData).Count)

  $existingRows = @(
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 100.0 -Run 1 -IsError $false),
    (& $makeRow -RuleName 'Alpha' -ElapsedMs 140.0 -Run 2 -IsError $false),
    (& $makeRow -RuleName 'Gamma' -ElapsedMs 900.0 -Run 1 -IsError $false)
  )
  $existing = @(Convert-RawResultsToAggregated -RawResults $existingRows)
  $newOnly = @(Convert-RawResultsToAggregated -RawResults @((& $makeRow -RuleName 'Beta' -ElapsedMs 500.0 -Run 1 -IsError $false)))
  $merged = @(Merge-AggregatedResultSet -NewResults $newOnly -ExistingResults $existing)
  $assert.Invoke('merge: entry count', ($merged.Count -eq 3), $merged.Count)
  $assert.Invoke('merge: carried rules keep their rows', (($merged | Where-Object { $_.RuleName -eq 'Alpha' }).Runs -eq 2), ($merged | Where-Object { $_.RuleName -eq 'Alpha' }).Runs)
  $assert.Invoke('merge: order', (($merged.RuleName -join ',') -eq 'Alpha,Beta,Gamma'), ($merged.RuleName -join ','))

  $sameRule = @(Convert-RawResultsToAggregated -RawResults @((& $makeRow -RuleName 'Alpha' -ElapsedMs 700.0 -Run 1 -IsError $false)))
  $replaced = @(Merge-AggregatedResultSet -NewResults $sameRule -ExistingResults $existing)
  $assert.Invoke('merge: re-run rule replaces itself', ($replaced.Count -eq 2), $replaced.Count)
  $assert.Invoke('merge: re-run rule uses new rows', (($replaced | Where-Object { $_.RuleName -eq 'Alpha' }).Runs -eq 1), ($replaced | Where-Object { $_.RuleName -eq 'Alpha' }).Runs)

  $empty = @(Convert-RawResultsToAggregated -RawResults @())
  $assert.Invoke('no rows: empty summary', ($empty.Count -eq 0), $empty.Count)

  $json = ConvertTo-Json -InputObject $single -Depth 5
  $assert.Invoke('one row: JSON stays an array', ($json.TrimStart()[0] -eq '['), $json.Substring(0, [math]::Min(20, $json.Length)))

  if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Output "FAIL: $failure" }
    throw "Aggregation self-test failed: $($failures.Count) assertion(s)."
  }
  Write-Output 'Aggregation self-test passed.'
}

if ($SelfTest) {
  Invoke-AggregationSelfTest
  exit 0
}

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
$allRules = @(Get-ScriptAnalyzerRule | Where-Object {
  $_.RuleName -notin $excludedRules -and $_.Severity -in $enabledSeverities
} | Sort-Object RuleName)

$totalRules = $allRules.Count
Write-Output "Enabled rules: $totalRules"

# ---------------------------------------------------------------------------
# Discover files for count display (subprocess discovers independently)
# ---------------------------------------------------------------------------
$paths = @(@(git ls-files '*.ps1') | Where-Object { Test-Path $_ })
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
$existingResults = @()
if ($SkipExisting -and (Test-Path $ResultsFile)) {
  try {
    $existingResults = @(Get-Content $ResultsFile -Raw | ConvertFrom-Json)
    foreach ($entry in $existingResults) {
      if ($entry.Runs -ge $Runs) {
        $null = $skipRules.Add($entry.RuleName)  # check-suppress:suppression_doc: HashSet.Add returns bool; set membership is the side effect
        Write-Output "Skipping $($entry.RuleName) (already recorded: $($entry.Runs))"
      }
    }
    Write-Output ""
  } catch {
    $existingResults = @()
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
$tasks = @($tasks | Sort-Object { Get-Random })
$totalTasks = $tasks.Count
Write-Output "Total benchmark tasks: $totalTasks"
Write-Output ""

# Nothing to run leaves a summary that already matches its rows, so the file is
# left untouched rather than rewritten.
if ($totalTasks -eq 0) {
  Write-Output "Nothing to benchmark: every enabled rule already meets -Runs $Runs in $ResultsFile"
  exit 0
}

Write-Output '=== BENCHMARKING ==='

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
  } elseif ($proc.ExitCode -ne 0) {
    $exitCode = $proc.ExitCode
    # Non-zero exit: try to parse stdout as JSON for structured error
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
    # Success: parse JSON
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
    ConvertTo-Json -InputObject $rawResults.ToArray() -Depth 5 | Set-Content $rawResultsFile
    $elapsed = [math]::Round($totalSw.Elapsed.TotalSeconds, 0)
    Write-Output "  [checkpoint saved: $incrementalCounter tasks in ${elapsed}s]"
  }
}

# Final raw save (catches remaining <10 tasks)
ConvertTo-Json -InputObject $rawResults.ToArray() -Depth 5 | Set-Content $rawResultsFile

$totalSw.Stop()

# ---------------------------------------------------------------------------
# Final aggregation
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output ('=== BENCHMARKING DONE === Total wall-clock: {0}s' -f [math]::Round($totalSw.Elapsed.TotalSeconds, 1))
if ($failedTasks -gt 0) { Write-Output "Failed tasks: $failedTasks" }

$newResults = @(Convert-RawResultsToAggregated -RawResults $rawResults.ToArray())
$allResults = @(Merge-AggregatedResultSet -NewResults $newResults -ExistingResults $existingResults)

if ($allResults.Count -eq 0) {
  throw "No successful rows to aggregate; raw results kept in $rawResultsFile"
}

Write-Output ''
Write-Output '=== TOP 10 SLOWEST (by MeanMs) ==='
$allResults | Sort-Object MeanMs -Descending | Select-Object -First 10 |
  Format-Table RuleName, Severity, MeanMs, MinMs, MaxMs, StdDevMs, MedianMs, MeanDiagCount -AutoSize

Write-Output ''
Write-Output '=== BOTTOM 5 (fastest) ==='
$allResults | Sort-Object MeanMs | Select-Object -First 5 |
  Format-Table RuleName, Severity, MeanMs, MinMs, MaxMs, StdDevMs, MedianMs, MeanDiagCount -AutoSize

Write-Output ''
if ($existingResults.Count -gt 0) {
  Write-Output ("Rules recorded in this run: {0}; carried over from the results file: {1}" -f $newResults.Count, ($allResults.Count - $newResults.Count))
  Write-Output ''
}
ConvertTo-Json -InputObject $allResults -Depth 5 | Set-Content $ResultsFile
Write-Output "Full results saved to: $ResultsFile"
Remove-Item $rawResultsFile -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: temp file may have already been cleaned up on previous run; deletion is best-effort
