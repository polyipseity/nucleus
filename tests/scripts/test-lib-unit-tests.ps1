#Requires -Version 7.4
# Unit tests for test-lib.ps1 (--skip-system-build removal and flag parsing).
#
# Verifies --skip-system-build is removed.

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

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testDir = Join-Path $repoRoot 'src\scripts\tests'
Set-StrictMode -Version Latest

# ---- Spec D: --skip-system-build removal ----
# NOTE: These tests use file content analysis because Read-Argument calls
# exit 1 on unknown flags, which terminates the PowerShell process.
# Direct invocation testing would kill the test runner.

# After removal, test-lib.ps1 Read-Argument must NOT have a --skip-system-build
# case. Verify by grepping the source file.
function Test-ParseArgsSkipSystemBuildRemoved {
    $testLibPs1 = Join-Path $testDir 'test-lib.ps1'
    $content = Get-Content -Path $testLibPs1 -Raw
    # The old --skip-system-build switch case should be gone.
    # Also check the usage action no longer mentions it.
    $hasFlagInSwitch = $content -match "'\^--skip-system-build\b"
    $hasFlagInUsage = $content -match 'skip-system-build'
    if (-not $hasFlagInSwitch -and -not $hasFlagInUsage) {
        Assert-Pass "test-lib Read-Argument has no --skip-system-build case after removal"
    } else {
        $details = @()
        if ($hasFlagInSwitch) { $details += "still has flag in switch" }
        if ($hasFlagInUsage) { $details += "still mentions flag in usage" }
        Assert-Fail "tdd-ps1-ssb-reject" "$($details -join '; ')"
    }
}

# The catch-all '-.*' pattern must still exist for unknown flags.
function Test-ParseArgsNoUnrecognizedFlag {
    $testLibPs1 = Join-Path $testDir 'test-lib.ps1'
    $content = Get-Content -Path $testLibPs1 -Raw
    if ($content -match "'\^-\.\*'") {
        Assert-Pass "test-lib Read-Argument still has catch-all '-.*' pattern"
    } else {
        Assert-Fail "tdd-ps1-unknown-flag" "Catch-all '-.*' pattern not found in Read-Argument switch"
    }
}

# Usage must not mention --skip-system-build after removal.
function Test-UsageNoSkipSystemBuild {
    $testLibPs1 = Join-Path $testDir 'test-lib.ps1'
    $content = Get-Content -Path $testLibPs1 -Raw
    if ($content -notmatch 'skip-system-build') {
        Assert-Pass "test-lib.ps1 does not mention --skip-system-build after removal"
    } else {
        Assert-Fail "tdd-ps1-usage-no-ssb" "test-lib.ps1 still mentions --skip-system-build"
    }
}

# ---- Run tests ----
Write-Output "`n=== Phase 2: test-lib unit tests (PS1) ==="
Write-Output ""

& Test-ParseArgsSkipSystemBuildRemoved
& Test-ParseArgsNoUnrecognizedFlag
& Test-UsageNoSkipSystemBuild

Write-Output "`n--- Phase 2 PS1 test-lib unit tests: $($script:passCount) passed, $($script:failCount) failed ---"
Write-Output ""

exit $script:failCount
