# Test: repo-policy-data (check step 13) step-local variable scope.
#
# Guards the $selfShLeaf derivation in the step 13 PowerShell body. Step 13
# read $selfShLeaf, which only step 12 assigns. Each step body runs in its own
# runspace, so that variable was never in scope: under StrictMode the body threw
# and the step died in 0.040s emitting no output at all, which is the second
# reason the Windows CI job was red.
#
# WHY this asserts the body RUNS rather than asserting a variable's value: the
# defect is invisible to any test that only inspects source, because the source
# looks reasonable. The observable difference is that the body produces its
# policy output instead of throwing.
#
# WHY it drives the step action rather than scripts/check.ps1: the runner
# refuses a windows-platform step on a POSIX host, so the host never executes
# the body. Dot-sourcing the step file and invoking $script:StepActions is the
# same path the runner uses, and tests/scripts/step-runner-unit-tests.ps1
# already does this.

#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failCount = 0

function Assert-Pass {
  param([string]$Name)
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$stepFile = Join-Path $repoRoot 'src/scripts/checks/check-steps/13-repo-policy-data.ps1'

# WHY: check-lib.ps1 sources step-runner.ps1 and defines the Write-* helpers the
# step body calls; it needs both variables set before it is dot-sourced.
$RepoRoot = $repoRoot
$FrameworkDir = Join-Path $repoRoot 'src/scripts/lib'
# WHY: check-lib.ps1 reads $FrameworkDir to locate src/scripts/lib. PSSA cannot
# see a read that happens through dot-sourcing, so reference the variable here.
$null = $FrameworkDir  # check-suppress:suppression_doc: cross-scope read by dot-sourced check-lib.ps1; PSSA cannot track it
. (Join-Path $repoRoot 'src/scripts/checks/check-lib.ps1')
. $stepFile

$stepIndex = $script:StepIds.IndexOf('repo-policy-data')
if ($stepIndex -lt 0) {
  Write-Output 'FAIL step 13 registers itself : step id not found after dot-sourcing'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}

$context = [pscustomobject]@{
  HasArgs        = $false
  RepoRoot       = $repoRoot
  PositionalArgs = @()
}

# 1. The body runs to completion instead of throwing on an unset variable.
$stepOutput = ''
$threw = $false
$throwMessage = ''
try {
  $stepOutput = & $script:StepActions[$stepIndex] $context 2>&1 | Out-String
} catch {
  $threw = $true
  $throwMessage = $_.Exception.Message
}

if ($threw) {
  Assert-Fail 'step 13: the body runs without an unset-variable error' $throwMessage
} else {
  Assert-Pass 'step 13: the body runs without an unset-variable error'
}

# 2. A body that threw produced zero output, which is what CI showed. Requiring
#    real output distinguishes "ran and was quiet" from "died silently".
if (-not $threw -and $stepOutput.Trim().Length -gt 0) {
  Assert-Pass 'step 13: the body emits its policy output'
} else {
  Assert-Fail 'step 13: the body emits its policy output' 'output was empty'
}

# 3. The step reached its end rather than dying partway. The final line is the
#    one the runner keys on, so its absence means the body never completed.
if (-not $threw -and $stepOutput -match 'repository policy \(data-driven\) passed') {
  Assert-Pass 'step 13: the body reaches the end of the data-driven policy'
} else {
  Assert-Fail 'step 13: the body reaches the end of the data-driven policy' 'completion line missing'
}

# 4. Every variable the body reads from its own scope is defined in its own
#    file. This is the general form of the defect: a step that borrows a
#    variable from a sibling step cannot run. It reads the shipped body and
#    checks each $self* reference resolves to a local assignment.
$source = Get-Content -LiteralPath $stepFile -Raw
$selfRefs = @(
  [regex]::Matches($source, '\$(self[A-Za-z]*)') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique
)
$missing = @(
  $selfRefs | Where-Object {
    $source -notmatch ('(?m)^\s*\$' + [regex]::Escape($_) + '\s*=')
  }
)
if ($missing.Count -eq 0) {
  Assert-Pass 'step 13: every $self* variable the body reads is assigned in this file'
} else {
  Assert-Fail 'step 13: every $self* variable the body reads is assigned in this file' "unassigned here: $($missing -join ', ')"
}

# 5. The two step files derive the POSIX twin name the same way, so the
#    exclusion cannot silently stop matching if either derivation changes.
$step12 = Get-Content -LiteralPath (Join-Path $repoRoot 'src/scripts/checks/check-steps/12-repo-policy-pattern.ps1') -Raw
$selfShDerivation = [regex]::Match($source, '(?m)^\s*\$selfShLeaf\s*=\s*(?<expr>.+?)\s*$')
$step12Derivation = [regex]::Match($step12, '(?m)^\s*\$selfShLeaf\s*=\s*(?<expr>.+?)\s*$')
if ($selfShDerivation.Success -and $step12Derivation.Success -and
    $selfShDerivation.Groups['expr'].Value -eq $step12Derivation.Groups['expr'].Value) {
  Assert-Pass 'step 13: the $selfShLeaf derivation matches step 12'
} else {
  Assert-Fail 'step 13: the $selfShLeaf derivation matches step 12' 'derivation differs or not found'
}

Write-Output ''
Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
