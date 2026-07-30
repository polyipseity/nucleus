#Requires -Version 7.4
# Framework library for check and test orchestrators (PowerShell).
# Provides step registration, execution, timing, and aggregation.
# Sourced by check-lib.ps1 and test-lib.ps1.

Set-StrictMode -Version Latest

# --- Step registration ---
$script:StepNumbers = [System.Collections.Generic.List[int]]::new()
$script:StepNames = [System.Collections.Generic.List[string]]::new()
$script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()

function Register-Step {
  param(
    [Parameter(Mandatory)]
    [int]$Number,
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [scriptblock]$Action
  )
  $script:StepNumbers.Add($Number)
  $script:StepNames.Add($Name)
  $script:StepActions.Add($Action)
}

# --- Wave parallelism infrastructure ---
$script:WaveTmpDir = $null

function Initialize-WaveTempDir {
  $script:WaveTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "nucleus-wave-$([System.IO.Path]::GetRandomFileName())"
  $null = New-Item -ItemType Directory -Path $script:WaveTmpDir -Force
  Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-WaveTempDir } | Out-Null
}

function Remove-WaveTempDir {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if ($script:WaveTmpDir -and (Test-Path $script:WaveTmpDir)) {
    Remove-Item -Path $script:WaveTmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
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
    $result = & $Action $script:HAS_ARGS $RepoRoot $script:WaveTmpDir $script:positionalArgs
    if ($result -eq $false) { $exitCode = 1 }
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
  if ($exitCode -ne 0 -and $script:FAIL_FAST) {
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
  $script:CachedNixFiles = Get-ChildItem -Recurse -Filter '*.nix' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object Name  # ref: allow-and-deny-lists.instructions.md#B7 — reason: structural invariant
  $script:CachedYamlFiles = Get-ChildItem -Recurse -Include '*.yml', '*.yaml' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object Name  # ref: allow-and-deny-lists.instructions.md#B7 — reason: structural invariant
  $script:CachedJsonFiles = Get-ChildItem -Path 'src' -Recurse -Filter '*.json' | Where-Object { $_.Name -notmatch '\.schema\.json$' -and $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object Name  # ref: allow-and-deny-lists.instructions.md#A7,#B7 — reason: schema files are meta; vendor is structural invariant
  $script:CachedShFiles = Get-ChildItem -Path 'src/scripts' -Recurse -Filter '*.sh' | Sort-Object Name
}

# --- Invoke-StepPipeline ---
function Invoke-StepPipeline {
  Initialize-WaveTempDir
  Save-FileListCache

  for ($i = 0; $i -lt $script:StepActions.Count; $i++) {
    Invoke-Step -Number $script:StepNumbers[$i] -Name $script:StepNames[$i] -Action $script:StepActions[$i]
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

  "`n  total:   {0,5} ms" -f $totalElapsed | Write-Output
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
