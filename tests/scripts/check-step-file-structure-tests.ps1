#!/usr/bin/env pwsh
# Verify every step file exists for both platforms and meets structural requirements.

$script:passCount = 0
$script:failCount = 0

function Assert-Pass([string]$name) {
  Write-Output "✓ $name"
  $script:passCount++
}

function Assert-Fail([string]$name, [string]$detail) {
  Write-Output "✗ $name — $detail"
  $script:failCount++
}

$repoRoot = Resolve-Path "$PSScriptRoot/../.."
$checkStepsDir = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps'
$testStepsDir = Join-Path -Path $repoRoot -ChildPath 'src/scripts/tests/test-steps'

# ---- Verify POSIX check step files ----
function PosixCheckStepFilesExist {
  $missing = 0
  foreach ($n in 1..26) {
    $pattern = Join-Path -Path $checkStepsDir -ChildPath "$("{0:D2}" -f $n)*.sh"
    if (-not (Test-Path -Path $pattern)) {
      Assert-Fail "POSIX check step $n" "Missing step file for number $n"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All 26 POSIX check step files exist"
  }
}

function PosixCheckStepHasRegisterStep {
  $missing = 0
  Get-ChildItem -Path "$checkStepsDir/*.sh" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if (-not ($content -match 'register_step "')) {
      Assert-Fail $_.Name "Missing register_step call"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All POSIX check step files have register_step"
  }
}

# ---- Verify POSIX test step files ----
function PosixTestStepFilesExist {
  $missing = 0
  foreach ($n in 1..4) {
    $pattern = Join-Path -Path $testStepsDir -ChildPath "0$n*.sh"
    if (-not (Test-Path -Path $pattern)) {
      Assert-Fail "POSIX test step $n" "Missing step file for number $n"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All 4 POSIX test step files exist"
  }
}

function PosixTestStepHasRegisterStep {
  $missing = 0
  Get-ChildItem -Path "$testStepsDir/*.sh" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if (-not ($content -match 'register_step "')) {
      Assert-Fail $_.Name "Missing register_step call"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All POSIX test step files have register_step"
  }
}

# ---- Verify Windows check step files ----
function WindowsCheckStepFilesExist {
  $missing = 0
  foreach ($n in 1..26) {
    $pattern = Join-Path -Path $checkStepsDir -ChildPath "$("{0:D2}" -f $n)*.ps1"
    if (-not (Test-Path -Path $pattern)) {
      Assert-Fail "Windows check step $n" "Missing step file for number $n"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All 26 Windows check step files exist"
  }
}

function WindowsCheckStepHasRegisterStep {
  $missing = 0
  Get-ChildItem -Path "$checkStepsDir/*.ps1" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if (-not ($content -match 'Register-Step -Id ')) {
      Assert-Fail $_.Name "Missing Register-Step call"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All Windows check step files have Register-Step"
  }
}

# ---- Verify Windows test step files ----
function WindowsTestStepFilesExist {
  $missing = 0
  foreach ($n in 1..4) {
    $pattern = Join-Path -Path $testStepsDir -ChildPath "0$n*.ps1"
    if (-not (Test-Path -Path $pattern)) {
      Assert-Fail "Windows test step $n" "Missing step file for number $n"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All 4 Windows test step files exist"
  }
}

function WindowsTestStepHasRegisterStep {
  $missing = 0
  Get-ChildItem -Path "$testStepsDir/*.ps1" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if (-not ($content -match 'Register-Step -Id ')) {
      Assert-Fail $_.Name "Missing Register-Step call"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All Windows test step files have Register-Step"
  }
}

# ---- Verify ordering loaders ----
function OrderingLoadersExist {
  $missing = 0
  foreach ($f in @('check-steps.sh', 'check-steps.ps1')) {
    $path = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks' -AdditionalChildPath $f
    if (-not (Test-Path -Path $path)) {
      Assert-Fail "Loader $f" "Missing"
      $missing++
    }
  }
  foreach ($f in @('test-steps.sh', 'test-steps.ps1')) {
    $path = Join-Path -Path $repoRoot -ChildPath 'src/scripts/tests' -AdditionalChildPath $f
    if (-not (Test-Path -Path $path)) {
      Assert-Fail "Loader $f" "Missing"
      $missing++
    }
  }
  if ($missing -eq 0) {
    Assert-Pass "All 4 ordering loaders exist"
  }
}

# ---- Verify POSIX check step IDs ----
function PosixCheckStepIdNoDigits {
  $violations = 0
  Get-ChildItem -Path "$checkStepsDir/*.sh" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'register_step "([^"]*)"') {
      $id = $Matches[1]
      if ($id -match '[0-9]') {
        Assert-Fail $_.Name "ID '$id' contains digit characters"
        $violations++
      }
    }
  }
  if ($violations -eq 0) {
    Assert-Pass "All POSIX check step IDs contain no digits"
  }
}

function PosixCheckStepIdUnique {
  $ids = Get-ChildItem -Path "$checkStepsDir/*.sh" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'register_step "([^"]*)"') {
      $Matches[1]
    }
  }
  $dups = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
  if (-not $dups) {
    Assert-Pass "All POSIX check step IDs are unique"
  } else {
    Assert-Fail "POSIX check step IDs" "Duplicate IDs: $($dups -join ', ')"
  }
}

# ---- Verify POSIX test step IDs ----
function PosixTestStepIdNoDigits {
  $violations = 0
  Get-ChildItem -Path "$testStepsDir/*.sh" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'register_step "([^"]*)"') {
      $id = $Matches[1]
      if ($id -match '[0-9]') {
        Assert-Fail $_.Name "ID '$id' contains digit characters"
        $violations++
      }
    }
  }
  if ($violations -eq 0) {
    Assert-Pass "All POSIX test step IDs contain no digits"
  }
}

function PosixTestStepIdUnique {
  $ids = Get-ChildItem -Path "$testStepsDir/*.sh" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'register_step "([^"]*)"') {
      $Matches[1]
    }
  }
  $dups = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
  if (-not $dups) {
    Assert-Pass "All POSIX test step IDs are unique"
  } else {
    Assert-Fail "POSIX test step IDs" "Duplicate IDs: $($dups -join ', ')"
  }
}

# ---- Verify PS1 check step IDs ----
function Ps1CheckStepIdNoDigits {
  $violations = 0
  Get-ChildItem -Path "$checkStepsDir/*.ps1" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'Register-Step -Id "([^"]*)"') {
      $id = $Matches[1]
      if ($id -match '[0-9]') {
        Assert-Fail $_.Name "ID '$id' contains digit characters"
        $violations++
      }
    }
  }
  if ($violations -eq 0) {
    Assert-Pass "All PS1 check step IDs contain no digits"
  }
}

function Ps1CheckStepIdUnique {
  $ids = Get-ChildItem -Path "$checkStepsDir/*.ps1" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'Register-Step -Id "([^"]*)"') {
      $Matches[1]
    }
  }
  $dups = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
  if (-not $dups) {
    Assert-Pass "All PS1 check step IDs are unique"
  } else {
    Assert-Fail "PS1 check step IDs" "Duplicate IDs: $($dups -join ', ')"
  }
}

# ---- Verify PS1 test step IDs ----
function Ps1TestStepIdNoDigits {
  $violations = 0
  Get-ChildItem -Path "$testStepsDir/*.ps1" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'Register-Step -Id "([^"]*)"') {
      $id = $Matches[1]
      if ($id -match '[0-9]') {
        Assert-Fail $_.Name "ID '$id' contains digit characters"
        $violations++
      }
    }
  }
  if ($violations -eq 0) {
    Assert-Pass "All PS1 test step IDs contain no digits"
  }
}

function Ps1TestStepIdUnique {
  $ids = Get-ChildItem -Path "$testStepsDir/*.ps1" | ForEach-Object {
    $content = Get-Content -Path $_.FullName -Raw
    if ($content -match 'Register-Step -Id "([^"]*)"') {
      $Matches[1]
    }
  }
  $dups = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
  if (-not $dups) {
    Assert-Pass "All PS1 test step IDs are unique"
  } else {
    Assert-Fail "PS1 test step IDs" "Duplicate IDs: $($dups -join ', ')"
  }
}

# ---- Run tests ----
Write-Output ""
Write-Output "Testing check/test step file structure..."
Write-Output ""

PosixCheckStepFilesExist
PosixCheckStepHasRegisterStep
PosixCheckStepIdNoDigits
PosixCheckStepIdUnique
PosixTestStepFilesExist
PosixTestStepHasRegisterStep
PosixTestStepIdNoDigits
PosixTestStepIdUnique
WindowsCheckStepFilesExist
WindowsCheckStepHasRegisterStep
WindowsTestStepFilesExist
WindowsTestStepHasRegisterStep
Ps1CheckStepIdNoDigits
Ps1CheckStepIdUnique
Ps1TestStepIdNoDigits
Ps1TestStepIdUnique
OrderingLoadersExist

Write-Output ""
Write-Output "--- Results: $passCount passed, $failCount failed ---"
Write-Output ""

exit $failCount
