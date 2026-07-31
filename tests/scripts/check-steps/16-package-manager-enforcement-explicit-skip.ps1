# Test: step 16 package-manager-enforcement PS1 must output explicit skip when scoped to non-shell files

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/16-package-manager-enforcement.ps1'

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

if ($content -match 'SKIPPED \(no shell files to check\)') {
  Assert-Pass -Name 'step16_ps1_has_skip' -Reason 'step 16 PS1 has explicit skip message for no shell files'
} else {
  Assert-Fail -Name 'step16_ps1_has_skip' -Reason 'step 16 PS1 should have explicit skip message for no shell files'
}

if ($script:failed) { exit 1 } else { exit 0 }
