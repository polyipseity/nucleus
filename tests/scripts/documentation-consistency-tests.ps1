# Documentation consistency tests for the step-runner framework (PS1).
# Verify that usage strings mention --skip-steps and don't mention removed flags.
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$checkScript = Join-Path -Path $repoRoot -ChildPath 'scripts\check.ps1'
$testScript = Join-Path -Path $repoRoot -ChildPath 'scripts\test.ps1'

$failed = $false

function Test-FileHasFlag {
  param([string]$Path, [string]$Flag)
  if (-not (Test-Path $Path)) {
    Write-Output "  SKIP: $Path not found"
    return $false
  }
  $content = Get-Content -Raw $Path
  return $content -match $Flag
}

function Test-FileNotHasFlag {
  param([string]$Path, [string]$Flag)
  if (-not (Test-Path $Path)) {
    return $true
  }
  $content = Get-Content -Raw $Path
  return $content -notmatch $Flag
}

# Header comment tests
function Test-CheckPs1HasSkipSteps {
  if (Test-FileHasFlag -Path $checkScript -Flag '--skip-steps') {
    Write-Output "  check.ps1 header: has --skip-steps"
  } else {
    Write-Output "FAIL: check.ps1 header should mention --skip-steps"
    $script:failed = $true
  }
}

function Test-CheckPs1NoFormat {
  if (Test-FileNotHasFlag -Path $checkScript -Flag '--format') {
    Write-Output "  check.ps1 header: no --format"
  } else {
    Write-Output "FAIL: check.ps1 header should NOT contain --format"
    $script:failed = $true
  }
}

function Test-TestPs1HasSkipSteps {
  if (Test-FileHasFlag -Path $testScript -Flag '--skip-steps') {
    Write-Output "  test.ps1 header: has --skip-steps"
  } else {
    Write-Output "FAIL: test.ps1 header should mention --skip-steps"
    $script:failed = $true
  }
}

function Test-TestPs1NoSkipSystemBuild {
  if (Test-FileNotHasFlag -Path $testScript -Flag '--skip-system-build') {
    Write-Output "  test.ps1 header: no --skip-system-build"
  } else {
    Write-Output "FAIL: test.ps1 header should NOT contain --skip-system-build"
    $script:failed = $true
  }
}

# Framework library tests
$checkLibPs1 = Join-Path $repoRoot 'src\scripts\checks\check-lib.ps1'
$testLibPs1 = Join-Path $repoRoot 'src\scripts\tests\test-lib.ps1'

function Test-CheckLibPs1HasSkipSteps {
  if (Test-FileHasFlag -Path $checkLibPs1 -Flag '--skip-steps') {
    Write-Output "  check-lib.ps1: has --skip-steps in usage"
  } else {
    Write-Output "FAIL: check-lib.ps1 should mention --skip-steps in usage"
    $script:failed = $true
  }
}

function Test-TestLibPs1HasSkipSteps {
  if (Test-FileHasFlag -Path $testLibPs1 -Flag '--skip-steps') {
    Write-Output "  test-lib.ps1: has --skip-steps in usage"
  } else {
    Write-Output "FAIL: test-lib.ps1 should mention --skip-steps in usage"
    $script:failed = $true
  }
}

function Test-TestLibPs1NoSkipSystemBuild {
  if (Test-FileNotHasFlag -Path $testLibPs1 -Flag '--skip-system-build') {
    Write-Output "  test-lib.ps1: no --skip-system-build in usage"
  } else {
    Write-Output "FAIL: test-lib.ps1 should NOT contain --skip-system-build"
    $script:failed = $true
  }
}

Write-Output "=== Documentation consistency tests (PS1) ==="
Test-CheckPs1HasSkipSteps
Test-CheckPs1NoFormat
Test-TestPs1HasSkipSteps
Test-TestPs1NoSkipSystemBuild
Test-CheckLibPs1HasSkipSteps
Test-TestLibPs1HasSkipSteps
Test-TestLibPs1NoSkipSystemBuild

if ($failed) { exit 1 } else { exit 0 }
