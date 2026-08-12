# Smoke tests for check-pwsh.ps1 CLI (-SkipStep, -Paths).
# Uses -SkipStep PSSA for syntax-only probes; check step 2 runs syntax on pre-commit.
# PSScriptAnalyzer runs in test step 2 (-SkipStep Syntax).

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
$pwshScript = Join-Path $repoRoot 'scripts\check-pwsh.ps1'

# 1. Syntax validation passes on a known-good file.
& $pwshScript -SkipStep PSSA -Paths $pwshScript > $null
if ($LASTEXITCODE -ne 0) {
  Assert-Fail 'check-pwsh: syntax validation on known-good file' "exit code $LASTEXITCODE"
} else {
  Assert-Pass 'check-pwsh: syntax validation passes on known-good file'
}

# 2. Syntax validation handles nonexistent files gracefully (skips them).
$missingPath = Join-Path $repoRoot 'nonexistent\missing-file.ps1'
& $pwshScript -SkipStep PSSA -Paths $missingPath > $null
if ($LASTEXITCODE -ne 0) {
  Assert-Fail 'check-pwsh: nonexistent file' "exit code $LASTEXITCODE"
} else {
  Assert-Pass 'check-pwsh: nonexistent file handled gracefully'
}

# 3. Unknown -SkipStep names produce an error.
$unknownSkipRejected = $false
try {
  & $pwshScript -SkipStep UnknownName -Paths $pwshScript > $null
  if ($LASTEXITCODE -ne 0) { $unknownSkipRejected = $true }
} catch {
  $unknownSkipRejected = $true
}
if ($unknownSkipRejected) {
  Assert-Pass 'check-pwsh: unknown -SkipStep name correctly rejected'
} else {
  Assert-Fail 'check-pwsh: unknown -SkipStep name should fail' 'expected non-zero exit or throw'
}

Write-Output ''
if ($script:failCount -gt 0) {
  Write-Output "check-pwsh smoke tests: $($script:failCount) failed, $($script:passCount) passed"
  exit 1
}

Write-Output "check-pwsh smoke tests: all $($script:passCount) passed"
