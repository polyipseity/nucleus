# Test: step 22 embedded-content enforcement PS1 must use AST here-string detection (embedded-content policy)

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/22-embedded-content-enforcement.ps1'
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

if ($content -match 'Parser\]::ParseFile') {
  Assert-Pass -Name 'step22_ps1_uses_ast' -Reason 'step 22 PS1 parses files with the PowerShell AST'
} else {
  Assert-Fail -Name 'step22_ps1_uses_ast' -Reason 'step 22 PS1 should parse files with the PowerShell AST'
}

if ($content -match 'HereString') {
  Assert-Pass -Name 'step22_ps1_herestrings' -Reason 'step 22 PS1 detects here-strings'
} else {
  Assert-Fail -Name 'step22_ps1_herestrings' -Reason 'step 22 PS1 should detect here-strings'
}

if ($content -match 'Set-Content.*Add-Content.*Out-File') {
  Assert-Pass -Name 'step22_ps1_disk_write' -Reason 'step 22 PS1 only flags here-strings written to disk'
} else {
  Assert-Fail -Name 'step22_ps1_disk_write' -Reason 'step 22 PS1 should only flag here-strings written to disk'
}

if ($content -match 'Add-Type') {
  Assert-Pass -Name 'step22_ps1_add_type' -Reason 'step 22 PS1 exempts Add-Type C# blocks (policy exception 3)'
} else {
  Assert-Fail -Name 'step22_ps1_add_type' -Reason 'step 22 PS1 should exempt Add-Type C# blocks (policy exception 3)'
}

if ($content -match 'check-suppress:embedded-content') {
  Assert-Pass -Name 'step22_ps1_citation' -Reason 'step 22 PS1 honors inline policy citation comments'
} else {
  Assert-Fail -Name 'step22_ps1_citation' -Reason 'step 22 PS1 should honor inline policy citation comments'
}

if ($content -match 'allow-and-deny-lists\.instructions\.md#C5') {
  Assert-Pass -Name 'step22_ps1_category_c' -Reason 'step 22 PS1 registers its self-exclusion in allow-and-deny-lists Category C'
} else {
  Assert-Fail -Name 'step22_ps1_category_c' -Reason 'step 22 PS1 should register its self-exclusion in allow-and-deny-lists Category C'
}

if ($script:failed) { exit 1 } else { exit 0 }
