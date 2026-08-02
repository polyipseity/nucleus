# Test: steps 21/22 scoped-mode file-list fix (Phase 14)
#
# Covers the nested if-expression $null crash: when scoped args contain zero
# ps1 files, the file-list expression must yield an empty array (not $null)
# so the .Count guards below do not throw under StrictMode. Also verifies
# scoped and full-mode scanning still behave after the @() wrapper.

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
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

# Stub the Write-* helpers defined by check-lib.ps1 (which imports a
# Windows-only module and cannot be dot-sourced in this harness). Mirror the
# real implementations ($args, no declared params) so PSSA does not flag them.
function Write-Message { Write-Output "check: $args" }
function Write-WarningMessage { Write-Output "check: warning: $args" }
function Write-ErrorMessage { Write-Output "check: error: $args" }

. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/step-runner.ps1')
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/21-preflight-install-command-policy.ps1')
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/22-embedded-content-enforcement.ps1')

function Get-StepAction {
  param([string]$Id)
  return $script:StepActions[$script:StepIds.IndexOf($Id)]
}

$action21 = Get-StepAction -Id 'preflight-install-command-policy'
$action22 = Get-StepAction -Id 'embedded-content-enforcement'

$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step21-22-" + [guid]::NewGuid().ToString('N'))
$fullDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step21-22-full-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force > $null
New-Item -ItemType Directory -Path $fullDir -Force > $null

# Fragment assembly keeps THIS file free of the literal patterns the steps
# detect (step 21: the marker and suffix fragments below, never adjacent on
# one line; step 22: here-strings written to disk; step 17: suppression
# idioms).
$fragTool = 'Assert-Tool' + 'Available'
$fragInstall = '-Install' + 'Command'
$fragHsOpen = '@' + '"'
$fragHsClose = '"' + '@'

$clean21 = Join-Path -Path $tmpDir -ChildPath 'clean21.ps1'
Set-Content -Path $clean21 -Value "Write-Output 'clean'"
$clean22 = Join-Path -Path $tmpDir -ChildPath 'clean22.ps1'
Set-Content -Path $clean22 -Value "Write-Output 'clean'"
$fullClean = Join-Path -Path $fullDir -ChildPath 'clean.ps1'
Set-Content -Path $fullClean -Value "Write-Output 'clean'"

# Violating fixtures: step 21 pattern and step 22 oversized here-string.
$violating21 = Join-Path -Path $tmpDir -ChildPath 'violating21.ps1'
Set-Content -Path $violating21 -Value ($fragTool + " -Name x $fragInstall 'y'")
$hsBody = 1..12 | ForEach-Object { "fixture body line $_" }
$violating22 = Join-Path -Path $tmpDir -ChildPath 'violating22.ps1'
Set-Content -Path $violating22 -Value ('Set-Content -Path x -Value ' + $fragHsOpen + "`n" + ($hsBody -join "`n") + "`n" + $fragHsClose)

# Invokes an action under the step-runner scoped/full contract. Returns $true
# when the action completes without throwing and reports no violation.
function Invoke-Action {
  param([scriptblock]$Action, [bool]$HasArgs, [string[]]$Positional, [string]$ScanRoot)
  $script:PS1_FILES = @()
  try {
    $out = @(& $Action -HasArgs $HasArgs -RepoRoot $ScanRoot -PositionalArgs $Positional)
  } catch {
    return $false
  }
  return ($out.Count -gt 0 -and $out[-1] -ne $false)
}

# (1) step 21 scoped, zero ps1 files -> no crash, clean pass
if (Invoke-Action -Action $action21 -HasArgs $true -Positional @('notes.txt') -ScanRoot $tmpDir) {
  Assert-Pass -Name 'step21_scoped_zero_ps1_no_crash' -Reason 'empty scoped file list yields an empty array, not $null'
} else {
  Assert-Fail -Name 'step21_scoped_zero_ps1_no_crash' -Reason 'empty scoped file list must not crash the .Count guard under StrictMode'
}

# (2) step 21 scoped, clean ps1 -> pass
if (Invoke-Action -Action $action21 -HasArgs $true -Positional @($clean21) -ScanRoot $tmpDir) {
  Assert-Pass -Name 'step21_scoped_clean_passes' -Reason 'scoped scan of a clean ps1 file finds no violations'
} else {
  Assert-Fail -Name 'step21_scoped_clean_passes' -Reason 'scoped scan of a clean ps1 file should pass'
}

# (3) step 21 scoped, violating ps1 -> violation detected
if (Invoke-Action -Action $action21 -HasArgs $true -Positional @($violating21) -ScanRoot $tmpDir) {
  Assert-Fail -Name 'step21_scoped_violation_detected' -Reason 'scoped scan should flag a preflight -InstallCommand call'
} else {
  Assert-Pass -Name 'step21_scoped_violation_detected' -Reason 'scoped scan flags a preflight -InstallCommand call'
}

# (4) step 22 scoped, zero ps1 files -> no crash, clean pass
if (Invoke-Action -Action $action22 -HasArgs $true -Positional @('notes.txt') -ScanRoot $tmpDir) {
  Assert-Pass -Name 'step22_scoped_zero_ps1_no_crash' -Reason 'empty scoped file list yields an empty array, not $null'
} else {
  Assert-Fail -Name 'step22_scoped_zero_ps1_no_crash' -Reason 'empty scoped file list must not crash the .Count guard under StrictMode'
}

# (5) step 22 scoped, clean ps1 -> pass
if (Invoke-Action -Action $action22 -HasArgs $true -Positional @($clean22) -ScanRoot $tmpDir) {
  Assert-Pass -Name 'step22_scoped_clean_passes' -Reason 'scoped scan of a clean ps1 file finds no violations'
} else {
  Assert-Fail -Name 'step22_scoped_clean_passes' -Reason 'scoped scan of a clean ps1 file should pass'
}

# (6) step 22 scoped, violating here-string -> violation detected
if (Invoke-Action -Action $action22 -HasArgs $true -Positional @($violating22) -ScanRoot $tmpDir) {
  Assert-Fail -Name 'step22_scoped_violation_detected' -Reason 'scoped scan should flag an oversized here-string written to disk'
} else {
  Assert-Pass -Name 'step22_scoped_violation_detected' -Reason 'scoped scan flags an oversized here-string written to disk'
}

# (7) step 21 full mode over a clean dir -> pass
if (Invoke-Action -Action $action21 -HasArgs $false -Positional @() -ScanRoot $fullDir) {
  Assert-Pass -Name 'step21_full_mode_passes' -Reason 'full-mode discovery still scans cleanly after the @() wrapper'
} else {
  Assert-Fail -Name 'step21_full_mode_passes' -Reason 'full-mode discovery should scan cleanly after the @() wrapper'
}

# (8) step 22 full mode over a clean dir -> pass
if (Invoke-Action -Action $action22 -HasArgs $false -Positional @() -ScanRoot $fullDir) {
  Assert-Pass -Name 'step22_full_mode_passes' -Reason 'full-mode discovery still scans cleanly after the @() wrapper'
} else {
  Assert-Fail -Name 'step22_full_mode_passes' -Reason 'full-mode discovery should scan cleanly after the @() wrapper'
}

Remove-Item -Path $tmpDir -Recurse -Force
Remove-Item -Path $fullDir -Recurse -Force

if ($script:failed) { exit 1 } else { exit 0 }
