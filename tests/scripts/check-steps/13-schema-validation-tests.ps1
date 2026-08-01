# Test: step 13 schema-validation PS1 must enforce $schema presence (Spec G)

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/13-schema-validation.ps1'
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

if ($content -match 'Missing.*`\$schema') {
  Assert-Pass -Name 'step13_ps1_missing_schema' -Reason 'step 13 PS1 checks for missing $schema'
} else {
  Assert-Fail -Name 'step13_ps1_missing_schema' -Reason 'step 13 PS1 should check for missing $schema'
}

if ($content -match 'Invalid.*`\$schema') {
  Assert-Pass -Name 'step13_ps1_format_check' -Reason 'step 13 PS1 checks for invalid $schema format'
} else {
  Assert-Fail -Name 'step13_ps1_format_check' -Reason 'step 13 PS1 should check for invalid $schema format'
}

if ($content -match 'schema.json|vendor|secrets') {
  Assert-Pass -Name 'step13_ps1_exception_list' -Reason 'step 13 PS1 has exception list'
} else {
  Assert-Fail -Name 'step13_ps1_exception_list' -Reason 'step 13 PS1 should have exception list'
}

if ($script:failed) { exit 1 } else { exit 0 }
