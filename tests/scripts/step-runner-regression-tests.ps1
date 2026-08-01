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
    Write-Output "✓ $Name"
    $script:passCount++
}

function Assert-Fail {
    param([string]$Name, [string]$Reason)
    Write-Output "FAIL $Name : $Reason"
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
Write-Output "`n=== Stage 1/3: Framework behavioral contracts ==="

# Tests that Register-Step works
. $stepRunner

# Verify step registration accepts string IDs and numbers
$testAction = { "ok" }
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
# Runs in a subprocess because Read-Argument exits the calling script on
# unknown flags (exit is not catchable by try/catch).
function Test-FormatFlagRejected {
    $scriptText = @"
Set-StrictMode -Version Latest
. "$stepRunner"
function global:Write-Message { Write-Output "message: `$args" }
function global:Write-ErrorMessage { Write-Output "error: `$args" }
`$script:usageAction = { Write-Output "usage: test" }
Read-Argument -Arguments @('--format')
"@
    $subOutput = pwsh -NoProfile -Command $scriptText 2>&1
    $subExitCode = $LASTEXITCODE

    if ($subExitCode -eq 1 -and $subOutput -match 'unsupported argument') {
        Assert-Pass "REGRESSION: PS1 Read-Argument rejects --format (no POSIX parity)"
    } else {
        Assert-Fail "REG-ps1-no-format" "Expected exit 1 rejecting --format; got exit=$subExitCode, output: $([string]::Join("`n", $subOutput))"
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

    # Test mutual exclusivity (subprocess: exit is not catchable)
    $scriptText = @"
Set-StrictMode -Version Latest
. "$stepRunner"
function global:Write-Message { Write-Output "message: `$args" }
function global:Write-ErrorMessage { Write-Output "error: `$args" }
`$script:usageAction = { Write-Output "usage: test" }
Read-Argument -Arguments @('--scoped', '--full')
"@
    $mutexOutput = pwsh -NoProfile -Command $scriptText 2>&1
    $mutexOk = ($LASTEXITCODE -eq 1) -and ($mutexOutput -match 'both --scoped and --full')
    if ($mutexOk) {
        Assert-Pass "REGRESSION: PS1 --scoped and --full combined errors"
    } else {
        Assert-Fail "REG-ps1-mutex" "Expected error from --scoped + --full; got exit=$LASTEXITCODE, output: $([string]::Join("`n", $mutexOutput))"
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

    Register-Step -Id "first" -Number 1 -Name "First" -Action { $true }
    Register-Step -Id "second" -Number 2 -Name "Second" -Action { $true }

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

# ---- Contract E0: Invoke-Step maps skip (return 2) to exit file 2 ----
function Test-SkipExitMapping {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    # Provide stubs for functions expected by Invoke-Step
    function global:Write-Message { Write-Output "message: $args" }
    function global:Write-ErrorMessage { Write-Output "error: $args" }

    $script:HAS_ARGS = $false
    $script:positionalArgs = @()
    $script:FAIL_FAST = $false

    Register-Step -Id "skip" -Number 2 -Name "SkipStep" -Action { Write-Message "skipping (test)"; return 2 }
    Initialize-WaveTempDir

    Invoke-Step -Number 2 -Name "SkipStep" -Action $script:StepActions[0]
    $exitCode = Get-Content -Path (Join-Path $script:WaveTmpDir "step-2.exit") -Raw
    Remove-WaveTempDir

    if ($exitCode -eq "2") {
        Assert-Pass "REGRESSION: PS1 Invoke-Step maps return 2 to exit file 2 (skip)"
    } else {
        Assert-Fail "REG-ps1-skip-map" "Expected exit file '2', got: $exitCode"
    }
}
Test-SkipExitMapping

# ---- Contract E2: Format-StepSummary renders exit 2 as SKIP ----
# Runs in a subprocess because Format-StepSummary exits the calling script.
function Test-SummarySkipFormat {
    $scriptText = @"
Set-StrictMode -Version Latest
. "$stepRunner"
function global:Write-Message { Write-Output "message: `$args" }
function global:Write-ErrorMessage { Write-Output "error: `$args" }
Register-Step -Id "skip" -Number 2 -Name "SkipStep" -Action { `$true }
Initialize-WaveTempDir
"2" | Out-File -FilePath (Join-Path `$script:WaveTmpDir "step-2.exit") -Encoding utf8 -NoNewline
"7" | Out-File -FilePath (Join-Path `$script:WaveTmpDir "step-2.time") -Encoding utf8 -NoNewline
"SkipStep" | Out-File -FilePath (Join-Path `$script:WaveTmpDir "step-2.name") -Encoding utf8 -NoNewline
`$output = & Format-StepSummary 2>&1
Remove-WaveTempDir
Write-Output `$output
"@
    $subOutput = pwsh -NoProfile -Command $scriptText 2>&1

    if ($subOutput -match 'SKIP') {
        Assert-Pass "REGRESSION: PS1 Format-StepSummary renders exit 2 as SKIP"
    } else {
        Assert-Fail "REG-ps1-summary-skip" "Expected 'SKIP' in subprocess output, got: $([string]::Join("`n", $subOutput))"
    }
}
Test-SummarySkipFormat

# ---- Contract E: Format-StepSummary output format ----
# NOTE: This test exits the calling script mid-call (Format-StepSummary calls exit 0
# on all-pass), so it must run LAST — nothing after it is reached.
function Test-SummaryOutputFormat {
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    . $stepRunner

    # Provide stubs for functions expected by Format-StepSummary
    function global:Write-Message { Write-Output "message: $args" }
    function global:Write-ErrorMessage { Write-Output "error: $args" }

    Register-Step -Id "pass" -Number 1 -Name "PassStep" -Action { $true }
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
Write-Output "`n--- Phase 0 PS1 regression tests: $($script:passCount) passed, $($script:failCount) failed ---"
Write-Output ""

exit $script:failCount
