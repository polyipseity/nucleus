# Smoke tests for check-pwsh.ps1 CLI (-OnlyStep, -Paths).
# Uses -OnlyStep Syntax for syntax-only probes, so the smoke test does not wait
# on the PSScriptAnalyzer pass; test step 2 runs PSSA with -OnlyStep PSSA.

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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$pwshScript = Join-Path $repoRoot 'src\scripts\checks\check-pwsh.ps1'
$pwsh = Join-Path -Path $PSHOME -ChildPath $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })

# WHY: each probe runs in a child pwsh process. An in-process `& $pwshScript` call
# never sets $LASTEXITCODE (the script only exits on failure), so under StrictMode
# the exit code is unobservable — and the exit code of the *process* is what this
# smoke test is about.

# 1. Syntax validation passes on a known-good file.
& $pwsh -NoLogo -NoProfile -NonInteractive -File $pwshScript -OnlyStep Syntax -Paths $pwshScript *> $null
if ($LASTEXITCODE -ne 0) {
  Assert-Fail 'check-pwsh: syntax validation on known-good file' "exit code $LASTEXITCODE"
} else {
  Assert-Pass 'check-pwsh: syntax validation passes on known-good file'
}

# 2. Syntax validation handles nonexistent files gracefully (skips them).
$missingPath = Join-Path $repoRoot 'nonexistent\missing-file.ps1'
& $pwsh -NoLogo -NoProfile -NonInteractive -File $pwshScript -OnlyStep Syntax -Paths $missingPath *> $null
if ($LASTEXITCODE -ne 0) {
  Assert-Fail 'check-pwsh: nonexistent file' "exit code $LASTEXITCODE"
} else {
  Assert-Pass 'check-pwsh: nonexistent file handled gracefully'
}

# 3. Unknown -OnlyStep values produce an error.
$unknownOnlyStepRejected = $false
try {
  & $pwsh -NoLogo -NoProfile -NonInteractive -File $pwshScript -OnlyStep UnknownName -Paths $pwshScript *> $null
  if ($LASTEXITCODE -ne 0) { $unknownOnlyStepRejected = $true }
} catch {
  $unknownOnlyStepRejected = $true
}
if ($unknownOnlyStepRejected) {
  Assert-Pass 'check-pwsh: unknown -OnlyStep value correctly rejected'
} else {
  Assert-Fail 'check-pwsh: unknown -OnlyStep value should fail' 'expected non-zero exit or throw'
}

Write-Output ''
if ($script:failCount -gt 0) {
  Write-Output "check-pwsh smoke tests: $($script:failCount) failed, $($script:passCount) passed"
  exit 1
}

Write-Output "check-pwsh smoke tests: all $($script:passCount) passed"
