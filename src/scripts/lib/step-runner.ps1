#Requires -Version 7.4
# Framework library for check and test orchestrators (PowerShell).
# Provides step registration, execution, timing, and aggregation.
# Sourced by check-lib.ps1 and test-lib.ps1.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "deny-list.ps1")

# --- Color support (F2/F3/F4) ---
# WHY: unified color detection — FORCE_COLOR/CLICOLOR_FORCE force on, NO_COLOR forces off,
# otherwise VT support + not redirected. Never mutates $PSStyle.OutputRendering.
$script:NucColorOn = $false
if ($env:NO_COLOR -and $env:NO_COLOR.Length -gt 0) {
  $script:NucColorOn = $false
} elseif (($env:FORCE_COLOR -and $env:FORCE_COLOR -ne '0') -or ($env:CLICOLOR_FORCE -and $env:CLICOLOR_FORCE.Length -gt 0)) {
  $script:NucColorOn = $true
} elseif ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected) {
  $script:NucColorOn = $true
}
if ($script:NucColorOn) {
  $script:NucStyleBold = $PSStyle.Bold
  $script:NucStyleDim = $PSStyle.Dim
  $script:NucStyleCyan = $PSStyle.Foreground.Cyan
  $script:NucStyleGreen = $PSStyle.Foreground.Green
  $script:NucStyleRed = $PSStyle.Foreground.Red
  $script:NucStyleYellow = $PSStyle.Foreground.Yellow
  $script:NucStyleReset = $PSStyle.Reset
} else {
  $script:NucStyleBold = ''
  $script:NucStyleDim = ''
  $script:NucStyleCyan = ''
  $script:NucStyleGreen = ''
  $script:NucStyleRed = ''
  $script:NucStyleYellow = ''
  $script:NucStyleReset = ''
}

# --- Step registration ---
$script:StepIds = [System.Collections.Generic.List[string]]::new()
$script:StepNumbers = [System.Collections.Generic.List[int]]::new()
$script:StepNames = [System.Collections.Generic.List[string]]::new()
# WHY: actions are stored as [scriptblock], not text closures. A runspace does
# not inherit the caller's function scope, so a closure over the lib's Write-*
# helpers silently fails ("not recognized"). The pipeline rebuilds the action via
# [scriptblock]::Create($Action.ToString()) inside the runspace's own scope after
# dot-sourcing the lib, so helpers resolve. Storing the [scriptblock] (not a
# string) also lets unit tests invoke actions directly via & $script:StepActions[i].
$script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
# Path to the framework lib (check-lib.ps1 / test-lib.ps1) the runspace dot-sources
# so step actions can call Write-ErrorMessage / Write-Message / Skip-Step / etc.
$script:StepLibPath = $null

function Format-StepDuration {
  param(
    [Parameter(Mandatory)]
    [long]$Milliseconds
  )
  return ('{0:F3} s' -f ($Milliseconds / 1000.0))
}

function Register-Step {
  param(
    [Parameter(Mandatory)]
    [string]$Id,
    [int]$Number = 0,
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

  # Number 0 is a sentinel: derive it from the registering file's NN- prefix.
  # $MyInvocation.PSCommandPath (not $PSCommandPath) is the caller's step file.
  if ($Number -eq 0) {
    $registeringFile = $MyInvocation.PSCommandPath
    if ((Split-Path -Leaf $registeringFile) -notmatch '^(\d{2})-') {
      throw "Register-Step: cannot derive step number from '$registeringFile' (expected NN- prefix); pass -Number explicitly"
    }
    $Number = [int]$Matches[1]
  }

  # Validate explicit number is a positive integer (0 is the derive sentinel).
  if ($Number -lt 1) {
    throw "Step number must be a positive integer, got $Number"
  }

  # Validate unique number (Spec A).
  if ($script:StepNumbers -contains $Number) {
    throw "Duplicate step number $Number"
  }

  $script:StepIds.Add($Id)
  $script:StepNumbers.Add($Number)
  $script:StepNames.Add($Name)
  # Store the action scriptblock. Unit tests invoke it directly via
  # & $script:StepActions[i]; the pipeline converts it to text for the runspace
  # via [scriptblock]::Create($Action.ToString()) (see Invoke-StepPipeline).
  $script:StepActions.Add($Action)
}

# WHY: the orchestrator lib (check-lib.ps1 / test-lib.ps1) sets this so the
# runspace can dot-source the same helpers the steps depend on.
function Set-StepLibPath {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path)
  if ($PSCmdlet.ShouldProcess('step lib path', 'Set')) {
    $script:StepLibPath = $Path
  }
}

# --- Step-number derivation helper ---
# Returns the step number for use inside step actions (e.g. skip messages).
# Prefers $Context.StepNumber (set by Invoke-StepPipeline per runspace step),
# because $MyInvocation.PSCommandPath is EMPTY inside a runspace — the step
# action is an in-memory scriptblock, not a file, so the filename-derived
# fallback cannot work there. Falls back to the filename prefix only on the
# main thread (non-runspace) where $MyInvocation.PSCommandPath is populated.
function Get-StepNumber {
  param(
    # WHY: the step context carries StepNumber. In the runspace, $MyInvocation.
    # PSCommandPath is EMPTY, so the filename fallback is unavailable; the caller
    # passes $Context explicitly. For direct/main-thread invocations (e.g. unit
    # tests) where $Context is not supplied, we fall back to the registering
    # file's NN- prefix via $MyInvocation.PSCommandPath.
    [PSObject]$Context
  )
  $ctx = $Context
  if (-not $ctx) {
    $callerCtx = Get-Variable -Name Context -Scope 1 -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: Scope-1 fallback when no explicit Context passed; variable may not exist
    if ($callerCtx) { $ctx = $callerCtx.Value }
  }
  if ($ctx -and $ctx.StepNumber) {
    return [int]$ctx.StepNumber
  }
  [int]((Split-Path -Leaf $MyInvocation.PSCommandPath) -replace '^(\d{2})-.*', '$1')
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
    # check-suppress:suppression_doc: best-effort temp-dir cleanup at exit; dir may already be gone.
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

# --- Skip-Step display helper ---
# WHY: runtime self-skips (scoped mode with no matching files) print the F3 skip header to
# stdout; display-only — the runner's own skip path writes the step files and exit-code marker.
function Skip-Step {
  param(
    [Parameter(Mandatory)]
    [int]$Number,
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$Reason
  )
  "`n$($script:NucStyleBold)$($script:NucStyleCyan)=== [$Number] $Name === SKIPPED ($Reason)$($script:NucStyleReset)" | Write-Output
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
  $script:CachedShellFiles = Get-ChildItem -Path 'src/scripts' -Recurse -Filter '*.sh' | Sort-Object Name | Select-GitIgnored
}

# --- Invoke-StepPipeline ---
# Parallel dispatch capped at PARALLEL_JOBS (wave batches).
function Invoke-StepPipeline {
  Initialize-WaveTempDir
  Save-FileListCache

  # Build the shared context object once; every step receives it explicitly as
  # its first parameter so no step reads enclosing $script: scope. Runspaces do
  # not inherit the caller's scope, so ambient $script: reads silently break.
  $contextObject = [PSCustomObject]@{
    HasArgs           = $script:HAS_ARGS
    RepoRoot          = $RepoRoot
    WaveTmpDir        = $script:WaveTmpDir
    FailFast          = $script:FAIL_FAST
    SkipSteps         = $script:SkipSteps
    Online            = $script:ONLINE
    ShFiles           = $script:SH_FILES
    Ps1Files          = $script:PS1_FILES
    PkrFiles          = $script:PKR_FILES
    NixFiles          = $script:NIX_FILES
    CachedShellFiles  = $script:CachedShellFiles
    CachedYamlFiles   = $script:CachedYamlFiles
    CachedJsonFiles   = $script:CachedJsonFiles
    CachedNixFiles    = $script:CachedNixFiles
    PositionalArgs    = $script:positionalArgs
    StepNumber        = 0
  }

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
      $null = $pendingIndices.Add($i)  # check-suppress:suppression_doc: List.Add return discarded; mutation is the side effect
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
      # WHY: the runspace body rebuilds the action as a scriptblock via
      # [scriptblock]::Create($ActionText). $Action is a [scriptblock] stored by
      # Register-Step; .ToString() recovers the source text for re-creation.
      $actionText = $action.ToString()

      # WHY: each runspace must get its OWN InitialSessionState. The default
      # InitialSessionState is shared process-wide; parallel runspaces autoloading
      # core modules into it race and corrupt the shared command table ("An item
      # with the same key has already been added" / "Destination array was not
      # long enough"), which silently kills runspaces. CreateDefault() gives each
      # runspace a full-language session with its own module state, isolating
      # autoload into independent session states.
      # WHY: the runspace body must NOT call Join-Path (or any cmdlet that
      # autoloads Microsoft.PowerShell.Management) during parallel startup. 14
      # runspaces autoloading that module into fresh ISS instances simultaneously
      # races and kills the runspaces. We build all per-step temp paths with
      # string concatenation ("$WaveTmpDir/step-$Number.xxx") instead of Join-Path
      # inside the body.
      $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
      $ps = [System.Management.Automation.PowerShell]::Create($iss)

      # WHY: dot-source the framework lib SYNCHRONOUSLY in the main thread
      # (before BeginInvoke) so each runspace's session state is fully
      # initialized without racing. 14 runspaces dot-sourcing the lib in parallel
      # corrupt the shared module/command state and silently kill the runspaces
      # (no exception surfaces; the runspace dies during the dot-source). Running
      # the dot-source here, sequentially per runspace, avoids the race while the
      # step itself still runs in parallel via BeginInvoke. The lib helpers
      # (Write-ErrorMessage, Skip-Step, Get-StepNumber, etc.) persist in the
      # runspace session state and are available to the step body below.
      $setup = {
        param($LibPath)
        if ($LibPath -and (Test-Path -LiteralPath $LibPath)) {
          # WHY: check-lib.ps1 / test-lib.ps1 expect $FrameworkDir and $RepoRoot
          # to be set in their scope (they dot-source step-runner.ps1 via
          # $FrameworkDir and import modules via $RepoRoot). The main thread sets
          # these before dot-sourcing the lib, but a runspace does not inherit the
          # caller's scope, so derive both from the lib path and set them here.
          # $LibPath = <RepoRoot>/src/scripts/{checks,tests}/<lib>.ps1
          #   Split-Path x2 -> <RepoRoot>/src/scripts ; join 'lib' -> FrameworkDir
          #   Split-Path x4 -> <RepoRoot>
          $FrameworkDir = Join-Path (Split-Path -Parent (Split-Path -Parent $LibPath)) 'lib'
          $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $LibPath))
          # WHY: $RepoRoot is consumed by the dot-sourced lib (test-lib.ps1 /
          # check-lib.ps1 read it for module paths) via shared dot-source scope.
          # PSSA cannot see the cross-scope read, so reference it here to avoid a
          # false PSUseDeclaredVarsMoreThanAssignments warning.
          $null = $RepoRoot  # check-suppress:suppression_doc: cross-scope read by dot-sourced lib; PSSA cannot track it
          # WHY: step-runner.ps1 dot-sources deny-list.ps1 via $PSScriptRoot, but
          # $PSScriptRoot is empty inside a runspace, so that dot-source silently
          # fails. Load deny-list.ps1 explicitly from the lib dir so Select-GitIgnored
          # and friends are available to the step body.
          . (Join-Path $FrameworkDir 'deny-list.ps1')
          . $LibPath
        }
      }
      # check-suppress:suppression_doc: AddScript/AddParameters return the pipeline for chaining; discarded
      $null = $ps.AddScript($setup).AddParameters(@{
        LibPath = $script:StepLibPath
      })
      $null = $ps.Invoke()  # check-suppress:suppression_doc: Invoke runs setup synchronously; output discarded

      # WHY: clone the shared context per step so StepNumber reflects THIS step.
      # The step action (and Get-StepNumber) reads $Context.StepNumber; a shared
      # context object cannot carry a per-step number, and $MyInvocation.PSCommandPath
      # is empty inside a runspace so the filename-derived fallback is unavailable.
      $stepContext = $contextObject.PSObject.Copy()
      $stepContext.StepNumber = $n

      $null = $ps.AddScript({  # check-suppress:suppression_doc: AddScript returns the pipeline for chaining; discarded
        param($Number, $Name, $ActionText, $Context, $WaveTmpDir, $FAIL_FAST, $Dim, $Reset)

        # WHY: the framework lib was already dot-sourced synchronously (see
        # $setup above), so its Write-* helpers and Skip-Step are in this
        # runspace's session state. We only run the step action here.
        # WHY: publish the step context to script scope so Get-StepNumber (a
        # function that cannot see this scriptblock's $Context parameter) can
        # read $script:Context.StepNumber. $MyInvocation.PSCommandPath is EMPTY
        # inside a runspace, so the filename fallback is unavailable here.
        $script:Context = $Context
        $stepStart = [System.Diagnostics.Stopwatch]::StartNew()
        $outFile = "$WaveTmpDir/step-$Number.out"
        "`n=== [$Number] $Name ===" | Out-File -FilePath $outFile -Encoding utf8
        $Name | Out-File -FilePath "$WaveTmpDir/step-$Number.name" -Encoding utf8 -NoNewline

        $exitCode = 0
        try {
          # WHY: create the action scriptblock in THIS scope (after the lib was
          # dot-sourced) so its Write-* calls resolve to the lib helpers, not the
          # absent main-session function table.
          $stepBlock = [scriptblock]::Create($ActionText)
          $stepOutput = & $stepBlock $Context 2>&1
          foreach ($line in $stepOutput) {
            $text = if ($line -is [System.Management.Automation.ErrorRecord]) { $line.ToString() } else { "$line" }
            Add-Content -Path $outFile -Value $text
            Write-Error ("{0}[step {1,2}]{2} {3}" -f $Dim, $Number, $Reset, $text)
          }
          $status = @($stepOutput)[-1]
          if ($status -is [int] -and $status -eq 2) { $exitCode = 2 }
          elseif ($status -eq $false) { $exitCode = 1 }
        } catch {
          $exitCode = 1
          "$_" | Out-File -FilePath $outFile -Encoding utf8 -Append
        }

        "$exitCode" | Out-File -FilePath "$WaveTmpDir/step-$Number.exit" -Encoding utf8 -NoNewline
        $stepStart.Stop()
        "$($stepStart.ElapsedMilliseconds)" | Out-File -FilePath "$WaveTmpDir/step-$Number.time" -Encoding utf8 -NoNewline

        if ($exitCode -ne 0 -and $exitCode -ne 2 -and $FAIL_FAST) {
          exit $exitCode
        }
      }).AddParameters(@{
        Number     = $n
        Name       = $name
        ActionText = $actionText
        Context    = $stepContext
        WaveTmpDir = $script:WaveTmpDir
        FAIL_FAST  = $script:FAIL_FAST
        Dim        = $script:NucStyleDim
        Reset      = $script:NucStyleReset
      })
      $handle = $ps.BeginInvoke()
      $null = $runspaces.Add(@{ PowerShell = $ps; AsyncResult = $handle; Number = $n })  # check-suppress:suppression_doc: List.Add return discarded; mutation is the side effect
      $startedSteps++
      $null = $spawnedNumbers.Add($n)  # check-suppress:suppression_doc: List.Add return discarded; mutation is the side effect
      Write-Output ("$($script:NucStyleDim)[{0}/{1}] step {2} {3} started$($script:NucStyleReset)" -f $startedSteps, $totalSteps, $n, $name)
    }

    $batchFailed = $false
    foreach ($rs in $runspaces) {
      try {
        $null = $rs.PowerShell.EndInvoke($rs.AsyncResult)  # check-suppress:suppression_doc: EndInvoke returns runspace output; already redirected to step out-file
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
    Write-Output ("$($script:NucStyleDim)step {0} finished ({1})$($script:NucStyleReset)" -f $n, (Format-StepDuration -Milliseconds $elapsedMs))
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

    # check-suppress:suppression_doc: probe -- exit file may not exist if step never ran; $null defaulted to '1' below
    $exitCode = Get-Content -Path (Join-Path $script:WaveTmpDir "step-$n.exit") -ErrorAction SilentlyContinue
    if (-not $exitCode) { $exitCode = "1" }
    # check-suppress:suppression_doc: probe -- time file may not exist if step never ran; $null defaulted to '0' below
    $elapsed = Get-Content -Path (Join-Path $script:WaveTmpDir "step-$n.time") -ErrorAction SilentlyContinue
    if (-not $elapsed) { $elapsed = "0" }
    $totalElapsed += [int]$elapsed

    if ($exitCode -eq "0") {
      "$($script:NucStyleDim)  step {0,2}  $($script:NucStyleGreen){1}$($script:NucStyleReset)$($script:NucStyleDim)  {2,8}  $($script:NucStyleReset){3}" -f $n, "✓", (Format-StepDuration -Milliseconds ([int]$elapsed)), $name | Write-Output
    } elseif ($exitCode -eq "2") {
      # Exit code 2 = skipped step; rendered as SKIP, never a failure.
      "$($script:NucStyleDim)  step {0,2}  $($script:NucStyleYellow){1}$($script:NucStyleReset)$($script:NucStyleDim)  {2,8}  $($script:NucStyleReset){3}" -f $n, "SKIP", (Format-StepDuration -Milliseconds ([int]$elapsed)), $name | Write-Output
    } else {
      "$($script:NucStyleDim)  step {0,2}  $($script:NucStyleRed){1}$($script:NucStyleReset)$($script:NucStyleDim)  {2,8}  $($script:NucStyleReset){3}" -f $n, "✗", (Format-StepDuration -Milliseconds ([int]$elapsed)), $name | Write-Output
      $failedSteps = "$failedSteps$n "
    }

    # Replay step output
    $outFile = Join-Path $script:WaveTmpDir "step-$n.out"
    if (Test-Path $outFile) {
      Get-Content -Path $outFile | ForEach-Object {
        if ($_ -match '^=== .* ===') { "$($script:NucStyleBold)$($script:NucStyleCyan)$_$($script:NucStyleReset)" }
        else { $_ }
      } | Write-Output
    }
  }

  $wallMs = 0
  $wallFile = Join-Path $script:WaveTmpDir 'pipeline.wall_ms'
  if (Test-Path -LiteralPath $wallFile) {
    $wallMs = [int](Get-Content -LiteralPath $wallFile -Raw)
  }

  "$($script:NucStyleDim)`n  sum of steps:$($script:NucStyleReset) {0,8}" -f (Format-StepDuration -Milliseconds $totalElapsed) | Write-Output
  "$($script:NucStyleDim)  wall clock:  $($script:NucStyleReset){0,8}" -f (Format-StepDuration -Milliseconds $wallMs) | Write-Output
  "`n" | Write-Output

  if ($failedSteps) {
    Write-ErrorMessage "$($script:NucStyleRed)some checks failed: steps $failedSteps$($script:NucStyleReset)"
    "  Failed steps: $failedSteps" | Write-Output
    exit 1
  } else {
    Write-Message "$($script:NucStyleGreen)all checks passed.$($script:NucStyleReset)"
    exit 0
  }
}

# --- Test-Prerequisite ---
function Test-Prerequisite {
  Assert-ToolAvailable -Name 'actionlint' -Type 'Command'
  Assert-ToolAvailable -Name 'check-jsonschema' -Type 'Command'
  Assert-ToolAvailable -Name 'jq' -Type 'Command'
  Assert-ToolAvailable -Name 'packer' -Type 'Command'
  Assert-ToolAvailable -Name 'pinact' -Type 'Command'
  Assert-ToolAvailable -Name 'shfmt' -Type 'Command'
  Assert-ToolAvailable -Name 'taplo' -Type 'Command'
  Assert-ToolAvailable -Name 'yamllint' -Type 'Command'
  Assert-ToolAvailable -Name 'yq' -Type 'Command'
  Assert-ToolAvailable -Name 'zizmor' -Type 'Command'
}
