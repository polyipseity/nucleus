#Requires -Version 7.4
# Phase 4a: Step 01 FORMAT_NIX removal — PS1 structure tests.
# These verify that FORMAT_NIX, --format references are gone
# from the PS1 step 01 file.
[CmdletBinding()]
param()

$script:passCount = 0
$script:failCount = 0
$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot) -Parent) -Parent

function Assert-Pass {
    param([string]$Name)
    Write-Output "$($PSStyle.Foreground.Green)✓ $Name$($PSStyle.Reset)"
    $script:passCount++
}

function Assert-Fail {
    param([string]$Name, [string]$Reason)
    Write-Output "$($PSStyle.Foreground.Red)FAIL $Name : $Reason$($PSStyle.Reset)"
    $script:failCount++
}

$step01file = Join-Path -Path $repoRoot -ChildPath "src/scripts/checks/check-steps/01-code-formatting.ps1"
$step01content = Get-Content -Raw -Path $step01file

Write-Output "=== Step 01 FORMAT_NIX removal tests (PS1) ==="

# Test: no FORMAT_NIX
if ($step01content -match 'FORMAT_NIX') {
    Assert-Fail "Step 01 PS1 still references FORMAT_NIX"
} else {
    Assert-Pass "Step 01 PS1 has no FORMAT_NIX references"
}

# Test: no --format flag reference
if ($step01content -match '--format') {
    Assert-Fail "Step 01 PS1 still references --format"
} else {
    Assert-Pass "Step 01 PS1 has no --format references"
}

# Test: no --fail-on-change
if ($step01content -match '--fail-on-change') {
    Assert-Fail "Step 01 PS1 still uses --fail-on-change"
} else {
    Assert-Pass "Step 01 PS1 has no --fail-on-change"
}

Write-Output "--- Step 01 PS1 tests: $($script:passCount) passed, $($script:failCount) failed ---"
if ($script:failCount -gt 0) { exit 1 }
