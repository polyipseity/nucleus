#Requires -Version 7.4
<#
.SYNOPSIS
  Repository test suite runner (Windows).

.DESCRIPTION
  Sources test-lib.ps1 for the framework and test-steps.ps1 for step
  registration, then runs the orchestration pipeline. Step logic lives in
  test-lib.ps1, step-runner.ps1, and files in test-steps/.

.PARAMETER FailFast
  Exit immediately on first failure (default).

.PARAMETER Help
  Show usage.

.PARAMETER ListSteps
  Print registered step IDs and exit.

.PARAMETER NoFailFast
  Accumulate all failures.

.PARAMETER NoVerbose
  Suppress step output streaming.

.PARAMETER OnlySteps
  Run only steps with the given comma-separated IDs.

.PARAMETER Verbose
  Stream step output; optional comma-separated step IDs.

.NOTES
  Environment variables:
    NUCLEUS_REPO_ROOT  Override the detected repository root path.
#>
param(
  [switch]$FailFast,
  [Alias('h')]
  [switch]$Help,
  [switch]$ListSteps,
  [switch]$NoFailFast,
  [switch]$NoVerbose,
  [string]$OnlySteps = '',
  [switch]$Verbose,
  [switch]$Scoped,
  [switch]$Full
)

. (Join-Path $PSScriptRoot '..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'
. (Join-Path $PSScriptRoot '..\src\scripts\lib\nucleus-cli-flags.ps1')

# WHY: with plain param() positional binding, stray positionals can be captured by string params.
$rawArgs = @($args)
function Test-NamedArg {
  param([string]$Name, [string[]]$Raw)
  foreach ($r in $Raw) {
    if ($r -eq "--$Name" -or $r -like "--$Name=*") { return $true }
  }
  return $false
}
$misbound = @()
if ($OnlySteps -and -not (Test-NamedArg -Name 'only-steps' -Raw $rawArgs)) { $misbound += $OnlySteps; $OnlySteps = '' }
$cliArgs = @($args) + @($misbound)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }

$TestDir = Join-Path $RepoRoot "src/scripts/tests"
$FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
$null = $FrameworkDir  # check-suppress:suppression_doc: consumed by test-lib.ps1 at runtime

. (Join-Path $TestDir "test-lib.ps1")
. (Join-Path $TestDir "test-steps.ps1")
. (Join-Path $RepoRoot "src/scripts/lib/bundle-freshness.ps1")

# WHY: --verbose is value-optional; capture =form ids before Resolve-NucleusArgument would reject them for a switch.
$verboseIds = ''
for ($_vi = 0; $_vi -lt $cliArgs.Count; $_vi++) {
  $_arg = [string]$cliArgs[$_vi]
  if ($_arg -eq '--verbose') { $Verbose = $true; continue }
  if ($_arg -like '--verbose=*') { $Verbose = $true; $verboseIds = $_arg.Substring('--verbose='.Length); $cliArgs[$_vi] = '--verbose' }
}

$leftover = @((Resolve-NucleusArgument -Arguments $cliArgs -CommandPath $PSCommandPath -CommandName 'test' -PassThroughUnknownFlags -BoundParameters $PSBoundParameters) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($leftover.Count -gt 0) {
  $_bad = [string]$leftover[0]
  if ($_bad -match '^-') {
    Write-ErrorMessage "unsupported argument '$_bad'"
  } else {
    Write-ErrorMessage "unexpected argument '$_bad'"
  }
  & $script:usageAction
  exit 1
}

if ($ListSteps) {
  Set-Location -Path $RepoRoot
  foreach ($id in $script:StepIds) { Write-Output $id }
  exit 0
}

$forwardArgs = [System.Collections.Generic.List[string]]::new()
if ($FailFast) { $forwardArgs.Add('--fail-fast') }
if ($NoFailFast) { $forwardArgs.Add('--no-fail-fast') }
if ($NoVerbose) { $forwardArgs.Add('--no-verbose') }
if ($Help) { $forwardArgs.Add('--help') }
if ($OnlySteps) { $forwardArgs.Add("--only-steps=$OnlySteps") }
if ($Scoped) { $forwardArgs.Add('--scoped') }
if ($Full) { $forwardArgs.Add('--full') }
if ($Verbose) {
  if ($verboseIds) { $forwardArgs.Add("--verbose=$verboseIds") }
  else { $forwardArgs.Add('--verbose') }
}

Read-Argument @($forwardArgs)
Test-Prerequisite
Write-BundleFreshnessNotice
Invoke-StepPipeline
Format-StepSummary
