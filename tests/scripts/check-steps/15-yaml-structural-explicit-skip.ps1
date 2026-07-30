# Test: step 15 yaml-structural PS1 must output explicit skip when no YAML files

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/15-yaml-structural.ps1'

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

if ($content -match 'SKIPPED.*no YAML files') {
  Assert-Pass -Name 'step15_ps1_has_skip' -Reason 'step 15 PS1 has explicit skip message for no YAML files'
} else {
  Assert-Fail -Name 'step15_ps1_has_skip' -Reason 'step 15 PS1 should have explicit skip message for no YAML files'
}

if ($script:failed) { exit 1 } else { exit 0 }
