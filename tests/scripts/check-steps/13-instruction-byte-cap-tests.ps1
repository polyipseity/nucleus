# Test: repo-policy-data (check step 13) instruction byte cap on Windows.
#
# The fixture repo points src at the live tree so the other step-13 subchecks
# keep their real inputs; only AGENTS.md and .agents/instructions come from the
# fixture. The step action then has to call the shared validator with the fixture
# root, print what the validator said, and return false when the fixture is over
# the cap.

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

# WHY: check-lib.ps1 sources step-runner.ps1, which owns the registered action.
# Both variables are read by the dot-sourced library, so they must exist first.
$RepoRoot = $repoRoot
$FrameworkDir = Join-Path $repoRoot 'src/scripts/lib'
$null = $FrameworkDir  # check-suppress:suppression_doc: cross-scope read by dot-sourced check-lib.ps1; PSSA cannot track it
. (Join-Path $repoRoot 'src/scripts/checks/check-lib.ps1')
. $stepFile

$stepIndex = $script:StepIds.IndexOf('repo-policy-data')
if ($stepIndex -lt 0) {
  Write-Output 'FAIL step 13 registers itself : repo-policy-data not found after dot-sourcing'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}

function Write-ExactFile {
  param([string]$Path, [string]$Prefix, [int]$Size)
  $bytes = [byte[]]::new($Size)
  $prefixBytes = [System.Text.Encoding]::ASCII.GetBytes($Prefix)
  [Array]::Copy($prefixBytes, $bytes, $prefixBytes.Length)
  for ($i = $prefixBytes.Length; $i -lt $Size; $i++) { $bytes[$i] = [byte]120 }
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-ByteCapFixture {
  [CmdletBinding(SupportsShouldProcess)]
  param([bool]$OverCap)
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('nucleus-byte-cap-' + [guid]::NewGuid().ToString('N'))
  if (-not $PSCmdlet.ShouldProcess($root, 'Create byte-cap fixture')) { return }
  $instructions = Join-Path $root '.agents/instructions'
  $null = New-Item -ItemType Directory -Path $instructions -Force
  $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'src') -Target (Join-Path $repoRoot 'src')
  $null = New-Item -ItemType SymbolicLink -Path (Join-Path $instructions 'upstream-workarounds.instructions.md') -Target (Join-Path $repoRoot '.agents/instructions/upstream-workarounds.instructions.md')

  $upstreamTarget = Join-Path $repoRoot '.agents/instructions/upstream-workarounds.instructions.md'
  $upstreamSize = (Get-Item -LiteralPath $upstreamTarget).Length
  $conditionalSize = if ($OverCap) { 20000 } else { 100000 - 2000 - 60000 - 30000 - $upstreamSize }

  Write-ExactFile -Path (Join-Path $root 'AGENTS.md') -Prefix "# Fixture`n" -Size 2000
  Write-ExactFile -Path (Join-Path $instructions 'policy.instructions.md') -Prefix "---`ndescription: ""Use when testing.""`nname: fixture-policy`napplyTo: ""**""`nalwaysApply: true`n---`n" -Size 60000
  Write-ExactFile -Path (Join-Path $instructions 'subject.reference.md') -Prefix "# Reference`n" -Size 30000
  Write-ExactFile -Path (Join-Path $instructions 'conditional.md') -Prefix "---`nalwaysApply: false`n---`n" -Size $conditionalSize
  return $root
}

function Remove-ByteCapFixture {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$Root)
  if (-not $PSCmdlet.ShouldProcess($Root, 'Remove byte-cap fixture')) { return }
  $link = Join-Path $Root 'src'
  if (Test-Path -LiteralPath $link) {
    Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: fixture link cleanup; the step never changes this link
  }
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: temp fixture cleanup; assertions already captured its result
}

function Invoke-Step13 {
  param([string]$FixtureRoot)
  $context = [pscustomobject]@{
    HasArgs        = $true
    RepoRoot       = $FixtureRoot
    PositionalArgs = @()
    Ps1Files       = @()
  }
  $raw = @()
  $threw = $false
  $message = ''
  try {
    $raw = @(& $script:StepActions[$stepIndex] $context 2>&1)
  } catch {
    $threw = $true
    $message = $_.Exception.Message
  }
  $returned = @($raw | Where-Object { $_ -is [bool] })
  $text = (@($raw | Where-Object { $_ -isnot [bool] }) | Out-String)
  $passed = if ($returned.Count -gt 0) { [bool]$returned[-1] } else { $false }
  return [pscustomobject]@{
    Passed = $passed
    Threw  = $threw
    Error  = $message
    Output = $text
  }
}

$overRoot = New-ByteCapFixture -OverCap $true
try {
  $result = Invoke-Step13 -FixtureRoot $overRoot
  if ($result.Threw) {
    Assert-Fail 'an over-cap fixture returns false from the Windows check step' "step threw: $($result.Error)"
  } elseif ($result.Passed) {
    Assert-Fail 'an over-cap fixture returns false from the Windows check step' "step passed; output=[$($result.Output)]"
  } else {
    Assert-Pass 'an over-cap fixture returns false from the Windows check step'
  }

  if ($result.Output -match 'check: error: instruction byte cap: \d+ bytes exceeds 100000 bytes') {
    Assert-Pass 'the Windows check step reports the validator diagnostic'
  } else {
    Assert-Fail 'the Windows check step reports the validator diagnostic' "output=[$($result.Output)]"
  }
} finally {
  Remove-ByteCapFixture -Root $overRoot
}

$exactRoot = New-ByteCapFixture -OverCap $false
try {
  $result = Invoke-Step13 -FixtureRoot $exactRoot
  if ($result.Threw -or -not $result.Passed) {
    Assert-Fail 'an exact-cap fixture passes the Windows check step' "threw=$($result.Threw) error=$($result.Error) output=[$($result.Output)]"
  } else {
    Assert-Pass 'an exact-cap fixture passes the Windows check step'
  }

  if ($result.Output -match 'check: instruction byte cap: 100000/100000 bytes') {
    Assert-Pass 'the Windows check step reports a passing validator result'
  } else {
    Assert-Fail 'the Windows check step reports a passing validator result' "output=[$($result.Output)]"
  }
} finally {
  Remove-ByteCapFixture -Root $exactRoot
}

Write-Output ''
Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
