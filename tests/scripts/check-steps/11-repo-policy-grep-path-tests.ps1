# Test: repo-policy-grep (check step 11) Windows path handling.
#
# Guards the svc_health_is_looping consumer allowlist in the step 11 PowerShell
# body. On Windows the file walk yields backslash-separated paths, and the
# allowlist is compared with -notcontains, which is string equality. Without
# normalization the derived path is `src\scripts\...`, can never equal the
# forward-slash allowlist entry, and both ALLOWED files are reported as
# violations. That is the red Windows CI job.
#
# WHY this reads the expression out of the step file instead of restating it:
# a test that hardcodes the corrected expression passes against the uncorrected
# source, so it cannot discriminate and proves nothing. Evaluating the shipped
# expression makes a revert of the fix fail this test.
#
# WHY it drives the step action rather than scripts/check.ps1: the runner
# refuses a windows-platform step on a POSIX host ("not applicable (platform:
# windows)"), so the host never executes the body. Dot-sourcing the step file
# and invoking $script:StepActions is the same path the runner uses, and
# tests/scripts/step-runner-unit-tests.ps1 already does this.

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
$stepFile = Join-Path $repoRoot 'src/scripts/checks/check-steps/11-repo-policy-grep.ps1'

# WHY: check-lib.ps1 sources step-runner.ps1 and defines the Write-* helpers the
# step body calls; it needs both variables set before it is dot-sourced.
$RepoRoot = $repoRoot
$FrameworkDir = Join-Path $repoRoot 'src/scripts/lib'
# WHY: check-lib.ps1 reads $FrameworkDir to locate src/scripts/lib. PSSA cannot
# see a read that happens through dot-sourcing, so reference the variable here.
$null = $FrameworkDir  # check-suppress:suppression_doc: cross-scope read by dot-sourced check-lib.ps1; PSSA cannot track it
. (Join-Path $repoRoot 'src/scripts/checks/check-lib.ps1')
. $stepFile

$stepIndex = $script:StepIds.IndexOf('repo-policy-grep')
if ($stepIndex -lt 0) {
  Write-Output 'FAIL step 11 registers itself : step id not found after dot-sourcing'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}

# The shipped allowlist, read from the step file so a change to it is observed
# rather than mirrored here.
$allowlistMatch = [regex]::Match(
  (Get-Content -LiteralPath $stepFile -Raw),
  "\`$ssAllowedConsumers\s*=\s*@\((?<body>[^)]*)\)"
)
if (-not $allowlistMatch.Success) {
  Write-Output 'FAIL step 11 allowlist is readable : $ssAllowedConsumers assignment not found'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}
$allowedConsumers = @(
  [regex]::Matches($allowlistMatch.Groups['body'].Value, "'([^']+)'") |
    ForEach-Object { $_.Groups[1].Value }
)

# The shipped relative-path derivation, read from the step file. This is the
# expression under test: it is evaluated, not restated.
$derivationMatch = [regex]::Match(
  (Get-Content -LiteralPath $stepFile -Raw),
  '(?m)^\s*\$ssConsumerRelative\s*=\s*(?<expr>.+?)\s*$'
)
if (-not $derivationMatch.Success) {
  Write-Output 'FAIL step 11 path derivation is readable : $ssConsumerRelative assignment not found'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}
$derivation = $derivationMatch.Groups['expr'].Value

# Invoke-ConsumerRule: run the shipped derivation and allowlist comparison over
# a caller set, and report what the step would flag.
#
# WHY the inputs are Windows-shaped: the separator the file walk produces is the
# only platform-dependent input to this comparison, so making it explicit is
# what lets a POSIX host exercise the Windows branch.
function Invoke-ConsumerRule {
  param(
    [string]$Root,
    [string[]]$ConsumerRelativePaths
  )

  $violations = @()
  foreach ($relative in $ConsumerRelativePaths) {
    # The step walks the tree and receives absolute paths; it then derives the
    # repo-relative form from them.
    $ssConsumerPath = $Root + $relative
    $r = $Root
    $ssConsumerRelative = & ([scriptblock]::Create($derivation))
    # WHY: the derivation just evaluated reads $ssConsumerPath and $r out of
    # this scope. Extracting it from the step file and evaluating it at runtime
    # is what makes a revert there change the code under test; PSSA cannot follow
    # [scriptblock]::Create(), so reference both variables here.
    $null = $ssConsumerPath  # check-suppress:suppression_doc: read by the runtime-evaluated derivation; PSSA cannot track it
    $null = $r  # check-suppress:suppression_doc: read by the runtime-evaluated derivation; PSSA cannot track it
    if ($allowedConsumers -notcontains $ssConsumerRelative) { $violations += $ssConsumerRelative }
  }
  return $violations
}

$windowsRoot = 'D:\a\nucleus\nucleus'
$windowsCallers = @(
  '\src\scripts\lib\service-health.sh',
  '\src\scripts\services\service-watchdog.sh'
)
$posixRoot = '/home/runner/work/nucleus'
$posixCallers = @(
  '/src/scripts/lib/service-health.sh',
  '/src/scripts/services/service-watchdog.sh'
)
$disallowedWindows = @('\src\services\some-other-daemon.sh')
$disallowedPosix = @('/src/services/some-other-daemon.sh')

# 1. Windows: the two ALLOWED callers must produce no violation. This is the
#    exact condition the red CI run reported.
$windowsAllowedViolations = @(Invoke-ConsumerRule -Root $windowsRoot -ConsumerRelativePaths $windowsCallers)
if ($windowsAllowedViolations.Count -eq 0) {
  Assert-Pass 'step 11: the two allowed callers produce no violation on Windows paths'
} else {
  Assert-Fail 'step 11: the two allowed callers produce no violation on Windows paths' "reported: $($windowsAllowedViolations -join ', ')"
}

# 2. Every allowed caller reported must be exactly the two the allowlist names.
#    Without this, an allowlist emptied to nothing would pass case 1.
if ($allowedConsumers.Count -eq 2) {
  Assert-Pass 'step 11: the allowlist still names exactly the two intended files'
} else {
  Assert-Fail 'step 11: the allowlist still names exactly the two intended files' "found $($allowedConsumers.Count) entries: $($allowedConsumers -join ', ')"
}

# 3. POSIX: unchanged behaviour. A fix that normalizes must not disturb the
#    platform that already worked.
$posixAllowedViolations = @(Invoke-ConsumerRule -Root $posixRoot -ConsumerRelativePaths $posixCallers)
if ($posixAllowedViolations.Count -eq 0) {
  Assert-Pass 'step 11: the two allowed callers produce no violation on POSIX paths'
} else {
  Assert-Fail 'step 11: the two allowed callers produce no violation on POSIX paths' "reported: $($posixAllowedViolations -join ', ')"
}

# 4. The rule is not disabled by the fix: a caller outside the allowlist is
#    still reported on both platforms. A comparison broken to report nothing
#    would otherwise pass cases 1 and 3.
$windowsDisallowed = @(Invoke-ConsumerRule -Root $windowsRoot -ConsumerRelativePaths $disallowedWindows)
if ($windowsDisallowed.Count -eq 1) {
  Assert-Pass 'step 11: a caller outside the allowlist is still reported on Windows'
} else {
  Assert-Fail 'step 11: a caller outside the allowlist is still reported on Windows' "expected 1 violation, got $($windowsDisallowed.Count)"
}

$posixDisallowed = @(Invoke-ConsumerRule -Root $posixRoot -ConsumerRelativePaths $disallowedPosix)
if ($posixDisallowed.Count -eq 1) {
  Assert-Pass 'step 11: a caller outside the allowlist is still reported on POSIX'
} else {
  Assert-Fail 'step 11: a caller outside the allowlist is still reported on POSIX' "expected 1 violation, got $($posixDisallowed.Count)"
}

# 5. The live body still runs end to end on this host and reports a clean
#    supervision scan, so the extraction above is reading live code rather than
#    a file that happens to parse.
$context = [pscustomobject]@{
  HasArgs        = $false
  RepoRoot       = $repoRoot
  PositionalArgs = @()
}
$stepOutput = & $script:StepActions[$stepIndex] $context 2>&1 | Out-String
if ($stepOutput -match 'svc_health_is_looping') {
  Assert-Fail 'step 11: the live body reports no loop-policy violation on a POSIX host' $stepOutput.Trim()
} elseif ($stepOutput -notmatch 'no service supervision invariant violations found') {
  Assert-Fail 'step 11: the live body reports no loop-policy violation on a POSIX host' 'supervision scan did not run'
} else {
  Assert-Pass 'step 11: the live body reports no loop-policy violation on a POSIX host'
}

Write-Output ''
Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
