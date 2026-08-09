#Requires -Version 7.4
# Framework library for check and test orchestrators (PowerShell).
# Provides step registration, execution, timing, and aggregation.
# Sourced by check-lib.ps1 and test-lib.ps1.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "deny-list.ps1")

# --- Step registration ---
$script:StepIds = [System.Collections.Generic.List[string]]::new()
$script:StepNumbers = [System.Collections.Generic.List[int]]::new()
$script:StepNames = [System.Collections.Generic.List[string]]::new()
$script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()

function Register-Step {
  param(
    [Parameter(Mandatory)]
    [string]$Id,
    [Parameter(Mandatory)]
    [int]$Number,
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [scriptblock]$Action
  )

  # Validate id not empty (Spec A).
  if ([string]::IsNullOrEmpty($Id)) {
    throw "Step ID must not be empty"
  }

  # Validate id contains no digits (Spec A).
  if ($Id -match '\d') {
    throw "Step ID '$Id' contains forbidden digit"
  }

  # Validate unique id (Spec A).
  if ($script:StepIds -contains $Id) {
    throw "Duplicate step ID '$Id'"
  }

  # Validate unique number (Spec A).
  if ($script:StepNumbers -contains $Number) {
    throw "Duplicate step number $Number"
  }

  $script:StepIds.Add($Id)
  $script:StepNumbers.Add($Number)
  $script:StepNames.Add($Name)
  $script:StepActions.Add($Action)
}

# --- Wave parallelism infrastructure ---
$script:WaveTmpDir = $null

function Initialize-WaveTempDir {
  $script:WaveTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "nucleus-wave-$([System.IO.Path]::GetRandomFileName())"
  $null = New-Item -ItemType Directory -Path $script:WaveTmpDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-WaveTempDir } > $null
}

function Remove-WaveTempDir {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if ($script:WaveTmpDir -and (Test-Path $script:WaveTmpDir)) {
    Remove-Item -Path $script:WaveTmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- Invoke-SkippedStep helper ---
function Invoke-SkippedStep {
  param(
    [int]$Number,
    [string]$Name,
    [string]$Id
  )
  $stepStart = [System.Diagnostics.Stopwatch]::StartNew()
  "`n=== [$Number] $Name === SKIPPED (--skip-steps: $Id)" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.out") -Encoding utf8
  $Name | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.name") -Encoding utf8 -NoNewline
  # Exit code 2 = skipped step (rendered as SKIP, not a failure).
  "2" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.exit") -Encoding utf8 -NoNewline
  $stepStart.Stop()
  "$($stepStart.ElapsedMilliseconds)" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.time") -Encoding utf8 -NoNewline
}

# --- Invoke-Step wrapper ---
# Owns ALL orchestration I/O: timing, section headers, exit file writing, fail-fast.
# Step actions receive params and write messages to stdout only.
function Invoke-Step {
  param(
    [Parameter(Mandatory)]
    [int]$Number,
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [scriptblock]$Action
  )

  $stepStart = [System.Diagnostics.Stopwatch]::StartNew()

  # 1. Write section header + step name
  "`n=== [$Number] $Name ===" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.out") -Encoding utf8
  $Name | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.name") -Encoding utf8 -NoNewline

  # 2. Run step action, capture ALL output
  $exitCode = 0
  try {
    $stepParams = @{ HasArgs = $script:HAS_ARGS; RepoRoot = $RepoRoot; WaveTmpDir = $script:WaveTmpDir; PositionalArgs = $script:positionalArgs }
    $result = & $Action @stepParams
    # Steps signal: pass ($true), fail ($false), or skip (int 2). The return value
    # is the LAST pipeline element. Type-check 2 because $true -eq 2 is True in PowerShell.
    $status = @($result)[-1]
    if ($status -is [int] -and $status -eq 2) { $exitCode = 2 }
    elseif ($status -eq $false) { $exitCode = 1 }
  } catch {
    $exitCode = 1
    Write-Output "ERROR: $_"
  }

  # 3. Write exit code and timing (framework owns these files)
  "$exitCode" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.exit") -Encoding utf8 -NoNewline
  $stepStart.Stop()
  $elapsedMs = $stepStart.ElapsedMilliseconds
  "$elapsedMs" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-$Number.time") -Encoding utf8 -NoNewline

  # 4. Fail-fast check
  # Exit code 2 = skipped step; never a failure, so never fail-fast on it.
  if ($exitCode -ne 0 -and $exitCode -ne 2 -and $script:FAIL_FAST) {
    exit $exitCode
  }
}

# --- Argument parsing ---
function Read-Argument {
  param([string[]]$Arguments)
  $script:FAIL_FAST = $false
  $script:ONLINE = $false
  $script:SCOPED = $false
  $script:FULL = $false
  $script:SkipSteps = @()
  $script:positionalArgs = @()

  $i = 0
  while ($i -lt $Arguments.Count) {
    switch -Regex ($Arguments[$i]) {
      '^-h$|^--help$' {
        & $script:usageAction
        exit 0
        break
      }
      '^--fail-fast$' {
        $script:FAIL_FAST = $true
        break
      }
      '^--no-fail-fast$' {
        $script:FAIL_FAST = $false
        break
      }
      '^--scoped$' {
        $script:SCOPED = $true
        break
      }
      '^--full$' {
        $script:FULL = $true
        break
      }
      '^--online$' {
        $script:ONLINE = $true
        break
      }
      '^--skip-steps=(.*)$' {
        $script:SkipSteps = @()
        $value = $Matches[1]
        if ($value) {
          $ids = $value -split ','
          foreach ($id in $ids) {
            $id = $id.Trim()
            if ($id -and $script:SkipSteps -notcontains $id) {
              $script:SkipSteps += $id
            }
          }
        }
        break
      }
      '^-.*' {
        Write-ErrorMessage "unsupported argument '$($Arguments[$i])'"
        & $script:usageAction
        exit 1
        break
      }
      default {
        $script:positionalArgs = $Arguments[$i..($Arguments.Count - 1)]
        break
      }
    }
    $i++
  }

  if ($script:SCOPED -and $script:FULL) {
    Write-ErrorMessage "cannot specify both --scoped and --full"
    & $script:usageAction
    exit 1
  }

  $script:HAS_ARGS = $script:positionalArgs.Count -gt 0
  if ($script:SCOPED) { $script:HAS_ARGS = $true }
  if ($script:FULL) { $script:HAS_ARGS = $false }

  # Group positional args by extension (matching POSIX Read-Argument behavior).
  $script:SH_FILES = @()
  $script:PS1_FILES = @()
  $script:PKR_FILES = @()
  $script:NIX_FILES = @()
  if ($script:HAS_ARGS) {
    foreach ($_f in $script:positionalArgs) {
      if ($_f -like '*.sh') { $script:SH_FILES += $_f }
      elseif ($_f -like '*.ps1') { $script:PS1_FILES += $_f }
      elseif ($_f -like '*.pkr.hcl') { $script:PKR_FILES += $_f }
      elseif ($_f -like '*.nix') { $script:NIX_FILES += $_f }
    }
  }
}

# --- File caching ---
function Save-FileListCache {
  $script:CachedNixFiles = Get-ChildItem -Recurse -Filter '*.nix' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object Name | Select-GitIgnored  # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  $script:CachedYamlFiles = Get-ChildItem -Recurse -Include '*.yml', '*.yaml' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object Name | Select-GitIgnored  # ref: allow-and-deny-lists.instructions.md#B7 -- structural invariant; gitignore filter applied on top
  $script:CachedJsonFiles = Get-ChildItem -Path 'src' -Recurse -Filter '*.json' | Where-Object { $_.Name -notmatch '\.schema\.json$' -and $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object Name | Select-GitIgnored  # ref: allow-and-deny-lists.instructions.md#A7,#B7 -- schema files are meta; vendor is structural invariant; gitignore filter applied on top
  $script:CachedShFiles = Get-ChildItem -Path 'src/scripts' -Recurse -Filter '*.sh' | Sort-Object Name | Select-GitIgnored
}

# --- Invoke-StepPipeline ---
# Parallel dispatch capped at PARALLEL_JOBS (wave batches).
function Invoke-StepPipeline {
  Initialize-WaveTempDir
  Save-FileListCache

  $maxJobs = if ($env:PARALLEL_JOBS) { [int]$env:PARALLEL_JOBS } else { [Environment]::ProcessorCount }
  if ($maxJobs -lt 1) { $maxJobs = 1 }

  $pipelineStart = [System.Diagnostics.Stopwatch]::StartNew()
  $totalSteps = $script:StepActions.Count
  $startedSteps = 0
  $pendingIndices = [System.Collections.Generic.List[int]]::new()
  $spawnedNumbers = [System.Collections.Generic.List[int]]::new()

  for ($i = 0; $i -lt $script:StepActions.Count; $i++) {
    $id = $script:StepIds[$i]
    $n = $script:StepNumbers[$i]
    $name = $script:StepNames[$i]

    $skip = $false
    if ($script:SkipSteps -and $script:SkipSteps.Count -gt 0) {
      if ($script:SkipSteps -contains $id) { $skip = $true }
    }

    if ($skip) {
      Invoke-SkippedStep -Number $n -Name $name -Id $id
    } else {
      $null = $pendingIndices.Add($i)
    }
  }

  $pos = 0
  while ($pos -lt $pendingIndices.Count) {
    $batchEnd = [Math]::Min($pos + $maxJobs, $pendingIndices.Count)
    $runspaces = [System.Collections.Generic.List[hashtable]]::new()

    while ($pos -lt $batchEnd) {
      $i = $pendingIndices[$pos]
      $pos++
      $n = $script:StepNumbers[$i]
      $name = $script:StepNames[$i]
      $action = $script:StepActions[$i]

      $ps = [System.Management.Automation.PowerShell]::Create()
      $null = $ps.AddScript({
        param($Number, $Name, $Action, $HasArgs, $RepoRoot, $WaveTmpDir, $FAIL_FAST)

        $stepStart = [System.Diagnostics.Stopwatch]::StartNew()
        $outFile = Join-Path $WaveTmpDir "step-$Number.out"
        "`n=== [$Number] $Name ===" | Out-File -FilePath $outFile -Encoding utf8
        $Name | Out-File -FilePath (Join-Path $WaveTmpDir "step-$Number.name") -Encoding utf8 -NoNewline

        $exitCode = 0
        try {
          $stepParams = @{ HasArgs = $HasArgs; RepoRoot = $RepoRoot; WaveTmpDir = $WaveTmpDir }
          $stepOutput = & $Action @stepParams 2>&1
          foreach ($line in $stepOutput) {
            $text = if ($line -is [System.Management.Automation.ErrorRecord]) { $line.ToString() } else { "$line" }
            Add-Content -Path $outFile -Value $text
            Write-Error ("[step {0,2}] {1}" -f $Number, $text)
          }
          $status = @($stepOutput)[-1]
          if ($status -is [int] -and $status -eq 2) { $exitCode = 2 }
          elseif ($status -eq $false) { $exitCode = 1 }
        } catch {
          $exitCode = 1
          "$_" | Out-File -FilePath $outFile -Encoding utf8 -Append
        }

        "$exitCode" | Out-File -FilePath (Join-Path $WaveTmpDir "step-$Number.exit") -Encoding utf8 -NoNewline
        $stepStart.Stop()
        "$($stepStart.ElapsedMilliseconds)" | Out-File -FilePath (Join-Path $WaveTmpDir "step-$Number.time") -Encoding utf8 -NoNewline

        if ($exitCode -ne 0 -and $exitCode -ne 2 -and $FAIL_FAST) {
          exit $exitCode
        }
      }).AddParameters(@{
        Number     = $n
        Name       = $name
        Action     = $action
        HasArgs    = $script:HAS_ARGS
        RepoRoot   = $RepoRoot
        WaveTmpDir = $script:WaveTmpDir
        FAIL_FAST  = $script:FAIL_FAST
      })
      $handle = $ps.BeginInvoke()
      $null = $runspaces.Add(@{ PowerShell = $ps; AsyncResult = $handle; Number = $n })
      $startedSteps++
      $null = $spawnedNumbers.Add($n)
      Write-Output ("[{0}/{1}] step {2} {3} started" -f $startedSteps, $totalSteps, $n, $name)
    }

    $batchFailed = $false
    foreach ($rs in $runspaces) {
      try {
        $null = $rs.PowerShell.EndInvoke($rs.AsyncResult)
      } catch {
        $batchFailed = $true
      } finally {
        $rs.PowerShell.Dispose()
      }
    }

    if ($batchFailed -and $script:FAIL_FAST) {
      exit 1
    }

    foreach ($rs in $runspaces) {
      $exitFile = Join-Path $script:WaveTmpDir "step-$($rs.Number).exit"
      if ((Test-Path -LiteralPath $exitFile) -and (Get-Content -LiteralPath $exitFile -Raw) -notin @('0', '2') -and $script:FAIL_FAST) {
        exit [int](Get-Content -LiteralPath $exitFile -Raw)
      }
    }
  }

  $pipelineStart.Stop()
  "$($pipelineStart.ElapsedMilliseconds)" | Out-File -FilePath (Join-Path $script:WaveTmpDir 'pipeline.wall_ms') -Encoding utf8 -NoNewline

  foreach ($n in $spawnedNumbers) {
    $timeFile = Join-Path $script:WaveTmpDir "step-$n.time"
    $elapsedMs = 0
    if (Test-Path -LiteralPath $timeFile) { $elapsedMs = [int](Get-Content -LiteralPath $timeFile -Raw) }
    $span = [TimeSpan]::FromMilliseconds($elapsedMs)
    Write-Output ("step {0} finished ({1:00}:{2:00})" -f $n, [math]::Floor($span.TotalMinutes), $span.Seconds)
  }
}

# --- Format-StepSummary ---
function Format-StepSummary {
  $totalSteps = $script:StepActions.Count
  $failedSteps = ""
  $totalElapsed = 0

  "" | Write-Output
  for ($i = 0; $i -lt $totalSteps; $i++) {
    $n = $script:StepNumbers[$i]
    $name = $script:StepNames[$i]

    $exitCode = Get-Content -Path (Join-Path $script:WaveTmpDir "step-$n.exit") -ErrorAction SilentlyContinue
    if (-not $exitCode) { $exitCode = "1" }
    $elapsed = Get-Content -Path (Join-Path $script:WaveTmpDir "step-$n.time") -ErrorAction SilentlyContinue
    if (-not $elapsed) { $elapsed = "0" }
    $totalElapsed += [int]$elapsed

    if ($exitCode -eq "0") {
      "  step {0,2}  {1}  {2,5} ms  {3}" -f $n, "✓", $elapsed, $name | Write-Output
    } elseif ($exitCode -eq "2") {
      # Exit code 2 = skipped step; rendered as SKIP, never a failure.
      "  step {0,2}  {1}  {2,5} ms  {3}" -f $n, "SKIP", $elapsed, $name | Write-Output
    } else {
      "  step {0,2}  {1}  {2,5} ms  {3}" -f $n, "✗", $elapsed, $name | Write-Output
      $failedSteps = "$failedSteps$n "
    }

    # Replay step output
    $outFile = Join-Path $script:WaveTmpDir "step-$n.out"
    if (Test-Path $outFile) {
      Get-Content -Path $outFile | Write-Output
    }
  }

  $wallMs = 0
  $wallFile = Join-Path $script:WaveTmpDir 'pipeline.wall_ms'
  if (Test-Path -LiteralPath $wallFile) {
    $wallMs = [int](Get-Content -LiteralPath $wallFile -Raw)
  }

  "`n  sum of steps: {0,5} ms" -f $totalElapsed | Write-Output
  "  wall clock:   {0,5} ms" -f $wallMs | Write-Output
  "`n" | Write-Output

  if ($failedSteps) {
    Write-ErrorMessage "some checks failed: steps $failedSteps"
    "  Failed steps: $failedSteps" | Write-Output
    exit 1
  } else {
    Write-Message "all checks passed."
    exit 0
  }
}

# --- Test-Prerequisite ---
function Test-Prerequisite {
  Assert-ToolAvailable -Name 'yamllint' -Type 'Command'
  Assert-ToolAvailable -Name 'jq' -Type 'Command'
  Assert-ToolAvailable -Name 'yq' -Type 'Command'
  Assert-ToolAvailable -Name 'check-jsonschema' -Type 'Command'
}
