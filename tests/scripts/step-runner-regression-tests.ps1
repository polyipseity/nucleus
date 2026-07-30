#Requires -Version 7.4
# Baseline regression tests for step-runner.ps1 (PowerShell).
# Captures current behavioral contracts before Phase 1-6 changes.
# ALL tests must pass on the current codebase.
#
# Phase 1 changes: step IDs (non-numeric), --skip-steps, PS1 parallelism
# Phase 2 changes: --skip-system-build removal
# Phase 3 changes: step registration updates

[CmdletBinding()]
param()

$script:passCount = 0
$script:failCount = 0

function Assert-Pass {
    param([string]$Name)
    Write-Host "✓ $Name" -ForegroundColor Green
    $script:passCount++
}

function Assert-Fail {
    param([string]$Name, [string]$Reason)
    Write-Host "FAIL $Name : $Reason" -ForegroundColor Red
    $script:failCount++
}

# Source the framework
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stepRunner = Join-Path $repoRoot 'src\scripts\lib\step-runner.ps1'

# ---- Setup: common stubs for tests ----
$script:usageAction = { Write-Output "usage: test" }
$script:RepoRoot = $repoRoot
Set-StrictMode -Version Latest

# ---- Contract A: Step IDs are currently numeric integers ----
Write-Host "`n=== Stage 1/3: Framework behavioral contracts ==="

# Tests that Register-Step works
. $stepRunner

# Verify step registration accepts string IDs and numbers
$testAction = { param($HasArgs, $RepoRoot) "ok" }
Register-Step -Id "first" -Number 1 -Name "Test" -Action $testAction
Register-Step -Id "second" -Number 2 -Name "Test2" -Action $testAction

if ($script:StepIds.Count -eq 2 -and $script:StepIds[0] -eq "first" -and $script:StepNumbers[0] -eq 1) {
    Assert-Pass "REGRESSION: Register-Step accepts string IDs and numbers"
} else {
    Assert-Fail "REG-ps1-ids" "Expected Ids=['first','second'], Numbers=[1,2]; got Ids=$($script:StepIds -join ','), Numbers=$($script:StepNumbers -join ',')"
}

# ---- Contract B2: --skip-system-build removed (Phase 2) ----
# Flag is no longer accepted by test-lib.ps1's Read-Argument.
# Uses file content analysis because Read-Argument calls exit 1 on unknown flags.

function Test-SkipSystemBuildFlagRemoved {
    $testLibPs1 = Join-Path $repoRoot 'src\scripts\tests\test-lib.ps1'
    $content = Get-Content -Path $testLibPs1 -Raw
    $hasFlagInSwitch = $content -match "'\^--skip-system-build\b"
    $hasFlagInUsage = $content -match 'skip-system-build'
    if (-not $hasFlagInSwitch -and -not $hasFlagInUsage) {
        Assert-Pass "REGRESSION: PS1 --skip-system-build is no longer accepted"
    } else {
        $details = @()
        if ($hasFlagInSwitch) { $details += "still has flag in switch" }
        if ($hasFlagInUsage) { $details += "still mentions flag in usage" }
        Assert-Fail "REG-ps1-skip-sys-build" "$($details -join '; ')"
    }
}
Test-SkipSystemBuildFlagRemoved

# ---- Contract B3: Read-Argument rejects unknown flags ----
# Tests that unknown flags (including --format) are rejected.
function Test-FormatFlagRejected {
    # Reset step arrays
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()

    $exitCode = 0
    try {
        & $stepRunner
        Read-Argument -Arguments @('--format')
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "REGRESSION: PS1 Read-Argument rejects --format (no POSIX parity)"
    } else {
        Assert-Fail "REG-ps1-no-format" "Expected --format to be rejected, but was accepted"
    }
}
Test-FormatFlagRejected

# ---- Contract C: scoped/full behavior ----
function Test-ScopedFullBehavior {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    Read-Argument -Arguments @('--scoped')
    $scopedOk = $script:SCOPED -eq $true
    $hasArgsOk = $script:HAS_ARGS -eq $true
    if ($scopedOk -and $hasArgsOk) {
        Assert-Pass "REGRESSION: PS1 --scoped sets SCOPED=true, HAS_ARGS=true"
    } else {
        Assert-Fail "REG-ps1-scoped" "Expected SCOPED=true, HAS_ARGS=true; got SCOPED=$($script:SCOPED), HAS_ARGS=$($script:HAS_ARGS)"
    }

    # Reset for --full test
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    Read-Argument -Arguments @('--full')
    if ($script:FULL -eq $true -and $script:HAS_ARGS -eq $false) {
        Assert-Pass "REGRESSION: PS1 --full sets FULL=true, HAS_ARGS=false"
    } else {
        Assert-Fail "REG-ps1-full" "Expected FULL=true, HAS_ARGS=false; got FULL=$($script:FULL), HAS_ARGS=$($script:HAS_ARGS)"
    }

    # Test mutual exclusivity
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    $mutexOk = $false
    try {
        Read-Argument -Arguments @('--scoped', '--full')
    } catch {
        $mutexOk = $true
    }
    if ($mutexOk) {
        Assert-Pass "REGRESSION: PS1 --scoped and --full combined errors"
    } else {
        Assert-Fail "REG-ps1-mutex" "Expected error from --scoped + --full, but none raised"
    }
}
Test-ScopedFullBehavior

# ---- Contract D: Invoke-StepPipeline uses parallelism (runspaces) ----
function Test-ParallelExecution {
    $script:StepIds = [System.Collections.Generic.List[string]]::new()
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    Register-Step -Id "first" -Number 1 -Name "First" -Action { param($HasArgs, $RepoRoot) $true }
    Register-Step -Id "second" -Number 2 -Name "Second" -Action { param($HasArgs, $RepoRoot) $true }

    # Analyze Invoke-StepPipeline source: it should use BeginInvoke/EndInvoke (runspaces)
    $source = Get-Content -Path $stepRunner -Raw
    $hasParallelPattern = $source -match 'BeginInvoke|RunspacePool|ForEach-Object -Parallel|Start-Job'

    if ($hasParallelPattern) {
        Assert-Pass "REGRESSION: PS1 Invoke-StepPipeline uses parallelism via runspaces"
    } else {
        Assert-Fail "REG-ps1-parallel" "Expected parallel pattern (BeginInvoke/RunspacePool), not found in source"
    }
}
Test-ParallelExecution

# ---- Contract E: Format-StepSummary output format ----
function Test-SummaryOutputFormat {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    # Provide stubs for functions expected by Format-StepSummary
    function global:Write-Message { Write-Output "message: $args" }
    function global:Write-ErrorMessage { Write-Output "error: $args" }

    Register-Step -Id "pass" -Number 1 -Name "PassStep" -Action { param($HasArgs, $RepoRoot) $true }
    Initialize-WaveTempDir

    # Simulate a run by writing files directly
    "0" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-1.exit") -Encoding utf8 -NoNewline
    "42" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-1.time") -Encoding utf8 -NoNewline
    "PassStep" | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-1.name") -Encoding utf8 -NoNewline

    $output = & Format-StepSummary 2>&1
    Remove-WaveTempDir

    if ($output -match 'step  1') {
        Assert-Pass "REGRESSION: PS1 Format-StepSummary outputs step summary table"
    } else {
        Assert-Fail "REG-ps1-summary" "Expected 'step  1' in output, got: $([string]::Join("`n", $output))"
    }
}
Test-SummaryOutputFormat

# ---- Results ----
Write-Host "`n--- Phase 0 PS1 regression tests: $($script:passCount) passed, $($script:failCount) failed ---"
Write-Host ""

exit $script:failCount
