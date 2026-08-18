# Test: step 17 activation-tool-resolution PS1 twin scans PowerShell activation scripts

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/17-activation-tool-resolution.ps1'
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

# Test: PS1 twin registers correct step ID
if ($content -match 'activation-tool-resolution') {
  Assert-Pass -Name 'step17_ps1_step_id' -Reason 'step 17 PS1 twin registers correct step ID'
} else {
  Assert-Fail -Name 'step17_ps1_step_id' -Reason 'step 17 PS1 twin should register step ID "activation-tool-resolution"'
}

# Test: PS1 twin scans PowerShell activation directories
if ($content -match 'Windows/modules') {
  Assert-Pass -Name 'step17_ps1_scans_windows_modules' -Reason 'step 17 PS1 twin scans Windows activation modules'
} else {
  Assert-Fail -Name 'step17_ps1_scans_windows_modules' -Reason 'step 17 PS1 twin should scan src/platforms/Windows/modules'
}

# Test: PS1 twin checks for Get-Command/Test-Path guards
if ($content -match 'Get-Command') {
  Assert-Pass -Name 'step17_ps1_get_command_guard' -Reason 'step 17 PS1 twin checks for Get-Command guard'
} else {
  Assert-Fail -Name 'step17_ps1_get_command_guard' -Reason 'step 17 PS1 twin should check for Get-Command guard'
}

if ($content -match 'Test-Path') {
  Assert-Pass -Name 'step17_ps1_test_path_guard' -Reason 'step 17 PS1 twin checks for Test-Path guard'
} else {
  Assert-Fail -Name 'step17_ps1_test_path_guard' -Reason 'step 17 PS1 twin should check for Test-Path guard'
}

# Test: PS1 twin has a high-risk tools list
if ($content -match 'highRiskTools') {
  Assert-Pass -Name 'step17_ps1_high_risk_tools' -Reason 'step 17 PS1 twin defines a high-risk tools list'
} else {
  Assert-Fail -Name 'step17_ps1_high_risk_tools' -Reason 'step 17 PS1 twin should define a high-risk tools list'
}

# Test: PS1 twin looks back for guard patterns
if ($content -match 'lookback|Lookback|lookback') {
  Assert-Pass -Name 'step17_ps1_lookback_guard' -Reason 'step 17 PS1 twin has lookback guard detection'
} else {
  Assert-Fail -Name 'step17_ps1_lookback_guard' -Reason 'step 17 PS1 twin should have lookback guard detection'
}

# Test: PS1 twin reports violations
if ($content -match 'bare external command') {
  Assert-Pass -Name 'step17_ps1_violation_message' -Reason 'step 17 PS1 twin reports violations with proper message'
} else {
  Assert-Fail -Name 'step17_ps1_violation_message' -Reason 'step 17 PS1 twin should report bare external command violations'
}

if ($script:failed) {
  exit 1
}
Write-Output "All step 17 PS1 tests passed."
