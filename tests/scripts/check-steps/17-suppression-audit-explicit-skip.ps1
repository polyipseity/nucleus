# Test: step 17 suppression-audit PS1 must output explicit skip when no files to check

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/17-suppression-audit.ps1'
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

if ($content -match 'SKIPPED.*no script files') {
  Assert-Pass -Name 'step17_ps1_has_skip' -Reason 'step 17 PS1 has explicit skip message for no script files'
} else {
  Assert-Fail -Name 'step17_ps1_has_skip' -Reason 'step 17 PS1 should have explicit skip message for no script files'
}

if ($script:failed) { exit 1 } else { exit 0 }
