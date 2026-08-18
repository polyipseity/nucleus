# Test: step 16 store-path-arg-usage PS1 twin skips (POSIX shell only check)

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/16-store-path-arg-usage.ps1'
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

if ($content -match 'Skip-Step') {
  Assert-Pass -Name 'step16_ps1_always_skips' -Reason 'step 16 PS1 twin always skips (POSIX shell only check)'
} else {
  Assert-Fail -Name 'step16_ps1_always_skips' -Reason 'step 16 PS1 twin should skip since this check only applies to shell scripts'
}

if ($content -match 'POSIX shell') {
  Assert-Pass -Name 'step16_ps1_skip_reason' -Reason 'step 16 PS1 twin skip reason mentions POSIX shell scripts'
} else {
  Assert-Fail -Name 'step16_ps1_skip_reason' -Reason 'step 16 PS1 twin skip reason should mention POSIX shell scripts'
}

if ($content -match 'store-path-arg-usage') {
  Assert-Pass -Name 'step16_ps1_step_id' -Reason 'step 16 PS1 twin registers correct step ID'
} else {
  Assert-Fail -Name 'step16_ps1_step_id' -Reason 'step 16 PS1 twin should register step ID "store-path-arg-usage"'
}

if ($script:failed) {
  exit 1
}
Write-Output "All step 16 PS1 tests passed."
