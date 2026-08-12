#Requires -Version 7.4
# Unit tests for step-runner.ps1 functions in isolation (PowerShell).
# Covers Spec A (step IDs) and Spec B (--skip-steps).

[CmdletBinding()]
param()

$script:passCount = 0
$script:failCount = 0
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stepRunner = Join-Path $repoRoot 'src\scripts\lib\step-runner.ps1'

function Assert-Pass {
    param([string]$Name)
    Write-Output "✓ $Name"
    $script:passCount++
}

function Assert-Fail {
    param([string]$Name, [string]$Reason)
    Write-Output "FAIL $Name : $Reason"
    $script:failCount++
}

# ---- Spec A: Step ID registration (new 4-arg form with -Id) ----

function Test-RegisterStep-WithId {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    Register-Step -Id "code-formatting" -Number 1 -Name "Code formatting" -Action { $true }

    if ($script:StepIds -and $script:StepIds[0] -eq "code-formatting" -and $script:StepNumbers[0] -eq 1) {
        Assert-Pass "Register-Step -Id stores id, number, name correctly"
    } else {
        $ids = if ($script:StepIds) { $script:StepIds[0] } else { "null" }
        Assert-Fail "Register-Step 4-arg" "Expected id='code-formatting' number=1, got id=$ids number=$($script:StepNumbers[0])"
    }
}

function Test-RegisterStep-MultipleWithId {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    Register-Step -Id "one" -Number 1 -Name "One" -Action { $true }
    Register-Step -Id "two" -Number 2 -Name "Two" -Action { $true }
    Register-Step -Id "three" -Number 3 -Name "Three" -Action { $true }

    if ($script:StepIds.Count -eq 3 -and $script:StepIds[0] -eq "one" -and $script:StepIds[2] -eq "three") {
        Assert-Pass "Register-Step accumulates multiple steps with IDs"
    } else {
        Assert-Fail "Register-Step multiple IDs" "Expected 3 IDs, got $($script:StepIds.Count)"
    }
}

function Test-RegisterStep-IdWithDigitError {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "test-1-bad" -Number 1 -Name "Bad" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step with digit in ID errors (Spec A)"
    } else {
        Assert-Fail "Register-Step digit ID" "Expected error for ID containing digit"
    }
}

function Test-RegisterStep-EmptyIdError {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "" -Number 1 -Name "Empty" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step with empty ID errors (Spec A)"
    } else {
        Assert-Fail "Register-Step empty ID" "Expected error for empty ID"
    }
}

function Test-RegisterStep-DuplicateIdError {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "dup" -Number 1 -Name "First" -Action { $true }
        Register-Step -Id "dup" -Number 2 -Name "Second" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step duplicate ID errors (Spec A)"
    } else {
        Assert-Fail "Register-Step dup ID" "Expected error for duplicate ID"
    }
}

function Test-RegisterStep-DuplicateNumberError {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "first" -Number 1 -Name "First" -Action { $true }
        Register-Step -Id "second" -Number 1 -Name "Second" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step duplicate number errors (Spec A)"
    } else {
        Assert-Fail "Register-Step dup num" "Expected error for duplicate number"
    }
}

# ---- Spec A: Step number derivation from NN- filename prefix ----

function Test-RegisterStep-DeriveNumberFromFilename {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("step-runner-test-" + [System.IO.Path]::GetRandomFileName())
    try {
        $null = New-Item -ItemType Directory -Path $tmpDir  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
        $fakeStep = Join-Path $tmpDir '05-fake.ps1'
        Set-Content -Path $fakeStep -Encoding utf8 -Value @(
            ". '$stepRunner'"
            "Register-Step -Id 'fake' -Name 'Fake' -Action { Write-Output (Get-StepNumber) }"
        )
        . $fakeStep

        if ($script:StepNumbers.Count -eq 1 -and $script:StepNumbers[0] -eq 5) {
            Assert-Pass "Register-Step derives step number from NN- filename prefix"
        } else {
            $num = if ($script:StepNumbers.Count -eq 1) { $script:StepNumbers[0] } else { "none" }
            Assert-Fail "Register-Step derive number" "Expected number 5, got $num"
        }

        $output = & $script:StepActions[0]
        if ($output -eq 5) {
            Assert-Pass "Get-StepNumber returns the step number inside a step action"
        } else {
            Assert-Fail "Get-StepNumber" "Expected output 5, got '$output'"
        }
    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) {
            # check-suppress:suppression_doc: best-effort temp-dir cleanup; dir may already be gone.
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-RegisterStep-DeriveNumberThrowsWithoutPrefix {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("step-runner-test-" + [System.IO.Path]::GetRandomFileName())
    $exitCode = 0
    try {
        $null = New-Item -ItemType Directory -Path $tmpDir  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
        $plainStep = Join-Path $tmpDir 'plain.ps1'
        Set-Content -Path $plainStep -Encoding utf8 -Value @(
            ". '$stepRunner'"
            "Register-Step -Id 'fake' -Name 'Fake' -Action { Write-Output (Get-StepNumber) }"
        )
        . $plainStep
    } catch {
        $exitCode = 1
    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) {
            # check-suppress:suppression_doc: best-effort temp-dir cleanup; dir may already be gone.
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($exitCode -eq 1 -and $script:StepNumbers.Count -eq 0) {
        Assert-Pass "Register-Step without NN- prefix errors and registers no step"
    } else {
        Assert-Fail "Register-Step derive error" "Expected error and 0 steps registered, got $($script:StepNumbers.Count) steps"
    }
}

# ---- Spec B: --skip-steps flag (via Read-Argument) ----

function Test-SkipSteps-EqualsForm {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $script:usageAction = { Write-Output "usage: test" }
    . $stepRunner

    Read-Argument -Arguments @('--skip-steps=a,b')

    if ($script:SkipSteps.Count -eq 2 -and $script:SkipSteps[0] -eq 'a' -and $script:SkipSteps[1] -eq 'b') {
        Assert-Pass "--skip-steps=a,b populates SkipSteps with two entries"
    } else {
        Assert-Fail "--skip-steps equals" "Expected 2 entries ['a','b'], got $($script:SkipSteps.Count): $($script:SkipSteps -join ',')"
    }
}

function Test-SkipSteps-EmptyValue {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $script:usageAction = { Write-Output "usage: test" }
    . $stepRunner

    Read-Argument -Arguments @('--skip-steps=')

    if ($script:SkipSteps.Count -eq 0) {
        Assert-Pass "--skip-steps= results in empty SkipSteps"
    } else {
        Assert-Fail "--skip-steps empty" "Expected 0 entries, got $($script:SkipSteps.Count)"
    }
}

function Test-SkipSteps-UnknownIdNoError {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $script:usageAction = { Write-Output "usage: test" }
    . $stepRunner

    $exitCode = 0
    try {
        Read-Argument -Arguments @('--skip-steps=nonexistent-id')
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 0) {
        Assert-Pass "--skip-steps with unknown ID does not error (Spec B)"
    } else {
        Assert-Fail "--skip-steps unknown" "Expected no error for unknown ID"
    }
}

function Test-SkipSteps-Dedup {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $script:usageAction = { Write-Output "usage: test" }
    . $stepRunner

    Read-Argument -Arguments @('--skip-steps=a,a')

    if ($script:SkipSteps.Count -eq 1 -and $script:SkipSteps[0] -eq 'a') {
        Assert-Pass "--skip-steps=a,a deduplicates to one entry"
    } else {
        Assert-Fail "--skip-steps dedup" "Expected 1 entry 'a', got $($script:SkipSteps.Count): $($script:SkipSteps -join ',')"
    }
}

function Test-SkipStep-LastValueWin {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $script:usageAction = { Write-Output "usage: test" }
    . $stepRunner

    Read-Argument -Arguments @('--skip-steps=a', '--skip-steps=b')

    if ($script:SkipSteps.Count -eq 1 -and $script:SkipSteps[0] -eq 'b') {
        Assert-Pass "--skip-steps last value wins (no accumulation)"
    } else {
        Assert-Fail "--skip-steps last-win" "Expected ['b'], got $($script:SkipSteps -join ',')"
    }
}

# ---- Run tests ----
Write-Output "`n=== Phase 1: Framework core unit tests (PS1) ==="
Write-Output "Tests for Spec A (step IDs) and Spec B (--skip-steps)."
Write-Output ""

Test-RegisterStep-WithId
Test-RegisterStep-MultipleWithId
Test-RegisterStep-IdWithDigitError
Test-RegisterStep-EmptyIdError
Test-RegisterStep-DuplicateIdError
Test-RegisterStep-DuplicateNumberError
Test-RegisterStep-DeriveNumberFromFilename
Test-RegisterStep-DeriveNumberThrowsWithoutPrefix
Test-SkipSteps-EqualsForm
Test-SkipSteps-EmptyValue
Test-SkipSteps-UnknownIdNoError
Test-SkipSteps-Dedup
Test-SkipStep-LastValueWin

Write-Output "`n--- Phase 1 PS1 unit tests: $($script:passCount) passed, $($script:failCount) failed ---"
Write-Output ""

exit $script:failCount
