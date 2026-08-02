# Test: step 19 config-method-compliance PS1 functional behavior
#
# Covers three pre-existing bugs fixed 2026-08-02 (all introduced at file
# creation, commit 5dfe301b4):
#   1. $using:parallelJobs in -ThrottleLimit parameter position -> always runtime error
#   2. string paths piped to Select-String are searched as content, never as files
#      (Select-GitIgnored returns path strings) -> both scans always empty
#   3. [regex]::Escape + -SimpleMatch -> dotted basenames (Windows.gitconfig) never match
# Plus the intended semantics the fixes restore: dotted-basename reference
# detection and the same-or-immediately-preceding-line annotation rule.

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/19-config-method-compliance.ps1'
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

# ---- Structural checks (bug fixes present) ----
$content = Get-Content -Path $testFile -Raw

if (-not $content.Contains('[regex]::Escape($_')) {
  Assert-Pass -Name 'step19_raw_patterns' -Reason 'step 19 uses raw basenames with -SimpleMatch (no [regex]::Escape mismatch)'
} else {
  Assert-Fail -Name 'step19_raw_patterns' -Reason 'step 19 must not combine [regex]::Escape with -SimpleMatch'
}

if ($content.Contains('Select-String -Path $srcFiles -Pattern $cfgPatterns -SimpleMatch')) {
  Assert-Pass -Name 'step19_path_reads_files' -Reason 'step 19 uses -Path so path strings are read as files, not searched as content'
} else {
  Assert-Fail -Name 'step19_path_reads_files' -Reason 'step 19 must read src files via Select-String -Path'
}

if (-not $content.Contains('ThrottleLimit $using:')) {
  Assert-Pass -Name 'step19_throttle_no_using' -Reason 'step 19 does not use $using: in -ThrottleLimit parameter position'
} else {
  Assert-Fail -Name 'step19_throttle_no_using' -Reason 'step 19 must not use $using: outside the -Parallel scriptblock'
}

if ($content.Contains('} -ThrottleLimit $parallelJobs')) {
  Assert-Pass -Name 'step19_throttle_canonical' -Reason 'step 19 places -ThrottleLimit after the -Parallel scriptblock'
} else {
  Assert-Fail -Name 'step19_throttle_canonical' -Reason 'step 19 must place -ThrottleLimit after the -Parallel scriptblock'
}

# ---- Behavioral checks (invoke the registered action directly) ----
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/deny-list.ps1')
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/step-runner.ps1')
. $testFile
$action = $script:StepActions[$script:StepActions.Count - 1]

$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step19-" + [guid]::NewGuid().ToString('N'))

function Invoke-ScopedStep19 {
  param([string]$FixtureRoot)
  $result = @(& $action -RepoRoot $FixtureRoot)
  return $result[-1]
}

# (1) dotted config + annotation immediately above reference -> pass
$fixture1 = Join-Path -Path $tmpDir -ChildPath 'case1'
$cfgDir = Join-Path -Path $fixture1 -ChildPath 'src/modules/configs/git'
New-Item -ItemType Directory -Path $cfgDir -Force > $null
Set-Content -Path (Join-Path $cfgDir 'Windows.gitconfig') -Value '[core]`nsymlinks=true'
$nixDir = Join-Path -Path $fixture1 -ChildPath 'src/modules'
New-Item -ItemType Directory -Path $nixDir -Force > $null
Set-Content -Path (Join-Path $nixDir 'fake.nix') -Value @(
  '# check-suppress:config-method: method 1 (writable symlink) -- fixture test'
  'ln -sf Windows.gitconfig /etc/gitconfig'
)
$status = Invoke-ScopedStep19 -FixtureRoot $fixture1
if ($status -eq $true) {
  Assert-Pass -Name 'step19_dotted_annotated_passes' -Reason 'dotted basename (Windows.gitconfig) found with annotation on preceding line -> pass'
} else {
  Assert-Fail -Name 'step19_dotted_annotated_passes' -Reason 'dotted basename reference with preceding annotation should pass'
}

# (2) dotted config + reference without annotation -> fail
$fixture2 = Join-Path -Path $tmpDir -ChildPath 'case2'
$cfgDir2 = Join-Path -Path $fixture2 -ChildPath 'src/modules/configs/git'
New-Item -ItemType Directory -Path $cfgDir2 -Force > $null
Set-Content -Path (Join-Path $cfgDir2 'Windows.gitconfig') -Value '[core]`nsymlinks=true'
$nixDir2 = Join-Path -Path $fixture2 -ChildPath 'src/modules'
New-Item -ItemType Directory -Path $nixDir2 -Force > $null
Set-Content -Path (Join-Path $nixDir2 'fake.nix') -Value 'ln -sf Windows.gitconfig /etc/gitconfig'
$status = Invoke-ScopedStep19 -FixtureRoot $fixture2
if ($status -eq $false) {
  Assert-Pass -Name 'step19_dotted_unannotated_fails' -Reason 'dotted basename reference without annotation -> fail'
} else {
  Assert-Fail -Name 'step19_dotted_unannotated_fails' -Reason 'dotted basename reference without annotation should fail'
}

# (3) annotation NOT immediately preceding (blank line gap) -> fail
$fixture3 = Join-Path -Path $tmpDir -ChildPath 'case3'
$cfgDir3 = Join-Path -Path $fixture3 -ChildPath 'src/modules/configs/git'
New-Item -ItemType Directory -Path $cfgDir3 -Force > $null
Set-Content -Path (Join-Path $cfgDir3 'Windows.gitconfig') -Value '[core]`nsymlinks=true'
$nixDir3 = Join-Path -Path $fixture3 -ChildPath 'src/modules'
New-Item -ItemType Directory -Path $nixDir3 -Force > $null
Set-Content -Path (Join-Path $nixDir3 'fake.nix') -Value @(
  '# check-suppress:config-method: method 1 (writable symlink) -- fixture test'
  ''
  'ln -sf Windows.gitconfig /etc/gitconfig'
)
$status = Invoke-ScopedStep19 -FixtureRoot $fixture3
if ($status -eq $false) {
  Assert-Pass -Name 'step19_annotation_gap_fails' -Reason 'annotation separated by blank line is not on or immediately preceding the reference -> fail'
} else {
  Assert-Fail -Name 'step19_annotation_gap_fails' -Reason 'annotation must be on the same or immediately preceding line of the reference'
}

# (4) host-parameterized config (${hostName}.gitconfig) with preceding annotation -> pass
$fixture4 = Join-Path -Path $tmpDir -ChildPath 'case4'
$cfgDir4 = Join-Path -Path $fixture4 -ChildPath 'src/modules/configs/git'
New-Item -ItemType Directory -Path $cfgDir4 -Force > $null
Set-Content -Path (Join-Path $cfgDir4 'MacBook.gitconfig') -Value '[core]`nsymlinks=true'
$nixDir4 = Join-Path -Path $fixture4 -ChildPath 'src/modules'
New-Item -ItemType Directory -Path $nixDir4 -Force > $null
Set-Content -Path (Join-Path $nixDir4 'fake.nix') -Value @(
  '# check-suppress:config-method: method 1 (writable symlink) -- fixture test'
  'ln -sf "${NUCLEUS_REPO_ROOT}/src/modules/configs/git/${hostName}.gitconfig" /etc/gitconfig'
)
$status = Invoke-ScopedStep19 -FixtureRoot $fixture4
if ($status -eq $true) {
  Assert-Pass -Name 'step19_hostname_template_passes' -Reason 'host-parameterized config (${hostName}.gitconfig) with preceding annotation -> pass'
} else {
  Assert-Fail -Name 'step19_hostname_template_passes' -Reason 'host-parameterized reference with preceding annotation should pass'
}

# (5) host-parameterized config without annotation -> fail
$fixture5 = Join-Path -Path $tmpDir -ChildPath 'case5'
$cfgDir5 = Join-Path -Path $fixture5 -ChildPath 'src/modules/configs/git'
New-Item -ItemType Directory -Path $cfgDir5 -Force > $null
Set-Content -Path (Join-Path $cfgDir5 'NixOS.gitconfig') -Value '[core]`nsymlinks=true'
$nixDir5 = Join-Path -Path $fixture5 -ChildPath 'src/modules'
New-Item -ItemType Directory -Path $nixDir5 -Force > $null
Set-Content -Path (Join-Path $nixDir5 'fake.nix') -Value 'ln -sf "${NUCLEUS_REPO_ROOT}/src/modules/configs/git/${hostName}.gitconfig" /etc/gitconfig'
$status = Invoke-ScopedStep19 -FixtureRoot $fixture5
if ($status -eq $false) {
  Assert-Pass -Name 'step19_hostname_template_unannotated_fails' -Reason 'host-parameterized reference without annotation -> fail'
} else {
  Assert-Fail -Name 'step19_hostname_template_unannotated_fails' -Reason 'host-parameterized reference without annotation should fail'
}

Remove-Item -Path $tmpDir -Recurse -Force

if ($script:failed) { exit 1 } else { exit 0 }
