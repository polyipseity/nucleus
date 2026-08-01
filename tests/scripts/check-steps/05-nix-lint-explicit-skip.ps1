# Test: step 05 PS1 already has skip message (nixf-tidy not available on Windows)

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/05-nix-lint.ps1'
$script:failed = $false

function Assert-Pass {
  param($Name, $Reason)
  Write-Output "PASS $Name : $Reason"
}

function Assert-Fail {
  param($Name, $Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failed = $true
}

$content = Get-Content -Path $testFile -Raw

if ($content -match 'skipping.*nixf-tidy not available on Windows') {
  Assert-Pass -Name 'step05_ps1_has_skip' -Reason 'step 05 PS1 already has skip message for nixf-tidy not available'
} else {
  Assert-Fail -Name 'step05_ps1_has_skip' -Reason 'step 05 PS1 should have skip message for nixf-tidy not available'
}

if ($script:failed) { exit 1 } else { exit 0 }
