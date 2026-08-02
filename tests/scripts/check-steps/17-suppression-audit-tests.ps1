# Test: step 17 suppression-audit PS1 functional behavior (fixed scanner)
#
# Covers: splat-bug fix (simple-match scans now work), $null =/[void] scans
# aligned to suppression_doc CheckId, | Out-Null rewrite-only semantics, sh
# || true scan, and the twin's own self-exclusion.

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
Set-StrictMode -Version Latest

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

# Stub the Write-* helpers defined by check-lib.ps1 (which imports a
# Windows-only module and cannot be dot-sourced in this harness). Mirror the
# real implementations ($args, no declared params) so PSSA does not flag them.
function Write-Message { Write-Output "check: $args" }
function Write-WarningMessage { Write-Output "check: warning: $args" }
function Write-ErrorMessage { Write-Output "check: error: $args" }

# ---- Structural checks (Phase 12 fixes present) ----
$content = Get-Content -Path $testFile -Raw

if ($content -match 'SimpleMatch = -not \$IsRegex') {
  Assert-Pass -Name 'step17_ps1_splat_fix' -Reason 'step 17 PS1 uses Pattern + SimpleMatch splat (no string-to-switch throw)'
} else {
  Assert-Fail -Name 'step17_ps1_splat_fix' -Reason 'step 17 PS1 should use Pattern + SimpleMatch splat'
}

if ($content -match 'allow-and-deny-lists\.instructions\.md#A9') {
  Assert-Pass -Name 'step17_ps1_self_exclusion' -Reason 'step 17 PS1 self-excludes via allow-and-deny A9'
} else {
  Assert-Fail -Name 'step17_ps1_self_exclusion' -Reason 'step 17 PS1 should self-exclude via allow-and-deny A9'
}

if ($content -notmatch 'ExemptLinePatterns') {
  Assert-Pass -Name 'step17_ps1_no_exempts' -Reason 'step 17 PS1 dropped the dead ExemptLinePatterns machinery'
} else {
  Assert-Fail -Name 'step17_ps1_no_exempts' -Reason 'step 17 PS1 should drop the dead ExemptLinePatterns machinery'
}

# ---- Behavioral checks (invoke the registered action directly) ----
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/step-runner.ps1')
. $testFile
$action = $script:StepActions[$script:StepActions.Count - 1]

$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step17-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force > $null

# Pattern fragments are assembled with concatenation so THIS test file never
# contains the raw suppression patterns the scanner detects.
$fragDiscard2 = '2>' + '$null'
$fragNullEq = '$null' + ' ='
$fragOutNull = '| Out' + '-Null'
$fragOrTrue = '||' + ' true'

function Invoke-ScopedStep17 {
  param([string[]]$ShFiles, [string[]]$NixFiles, [string[]]$Ps1Files)
  $script:SH_FILES = @($ShFiles)
  $script:NIX_FILES = @($NixFiles)
  $script:PS1_FILES = @($Ps1Files)
  $result = @(& $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @())
  return $result[-1]
}

# (1) 2>$null undocumented -> fail
$fixture = Join-Path -Path $tmpDir -ChildPath 'case1.ps1'
Set-Content -Path $fixture -Value "Write-Output 'x' $fragDiscard2"
$status = Invoke-ScopedStep17 -Ps1Files @($fixture)
if ($status -eq $false) {
  Assert-Pass -Name 'step17_2null_undocumented_fails' -Reason "simple-match scan flags undocumented $fragDiscard2"
} else {
  Assert-Fail -Name 'step17_2null_undocumented_fails' -Reason "simple-match scan should flag undocumented $fragDiscard2 (splat fix)"
}

# (2) 2>$null documented same-line -> pass
Set-Content -Path $fixture -Value "Write-Output 'x' $fragDiscard2  # check-suppress:suppression_doc: test discard"
$status = Invoke-ScopedStep17 -Ps1Files @($fixture)
if ($status -eq $true) {
  Assert-Pass -Name 'step17_2null_documented_passes' -Reason "same-line suppression_doc documents $fragDiscard2"
} else {
  Assert-Fail -Name 'step17_2null_documented_passes' -Reason "same-line suppression_doc should document $fragDiscard2"
}

# (3) $null = undocumented -> fail (proves suppression_doc CheckId)
Set-Content -Path $fixture -Value "$fragNullEq 1"
$status = Invoke-ScopedStep17 -Ps1Files @($fixture)
if ($status -eq $false) {
  Assert-Pass -Name 'step17_null_eq_undocumented_fails' -Reason "$fragNullEq is a suppression_doc family violation when undocumented"
} else {
  Assert-Fail -Name 'step17_null_eq_undocumented_fails' -Reason "$fragNullEq should be a suppression_doc family violation when undocumented"
}

# (4) $null = documented -> pass
Set-Content -Path $fixture -Value "$fragNullEq 1  # check-suppress:suppression_doc: test discard"
$status = Invoke-ScopedStep17 -Ps1Files @($fixture)
if ($status -eq $true) {
  Assert-Pass -Name 'step17_null_eq_documented_passes' -Reason "suppression_doc documents $fragNullEq"
} else {
  Assert-Fail -Name 'step17_null_eq_documented_passes' -Reason "suppression_doc should document $fragNullEq"
}

# (5) | Out-Null + annotation -> still fail (NoSuppressionCheck)
Set-Content -Path $fixture -Value "cmd $fragOutNull  # check-suppress:suppression_doc: test discard"
$status = Invoke-ScopedStep17 -Ps1Files @($fixture)
if ($status -eq $false) {
  Assert-Pass -Name 'step17_outnull_annotation_still_fails' -Reason "$fragOutNull cannot be annotation-suppressed (rewrite only)"
} else {
  Assert-Fail -Name 'step17_outnull_annotation_still_fails' -Reason "$fragOutNull should not be annotation-suppressible (rewrite only)"
}

# (6) sh || true undocumented -> fail
$shFixture = Join-Path -Path $tmpDir -ChildPath 'case6.sh'
Set-Content -Path $shFixture -Value "command $fragOrTrue"
$status = Invoke-ScopedStep17 -ShFiles @($shFixture)
if ($status -eq $false) {
  Assert-Pass -Name 'step17_or_true_undocumented_fails' -Reason 'sh || true is flagged when undocumented'
} else {
  Assert-Fail -Name 'step17_or_true_undocumented_fails' -Reason 'sh || true should be flagged when undocumented'
}

# (7) sh || true documented -> pass
Set-Content -Path $shFixture -Value "command $fragOrTrue  # check-suppress:suppression_doc: test discard"
$status = Invoke-ScopedStep17 -ShFiles @($shFixture)
if ($status -eq $true) {
  Assert-Pass -Name 'step17_or_true_documented_passes' -Reason 'suppression_doc documents sh || true'
} else {
  Assert-Fail -Name 'step17_or_true_documented_passes' -Reason 'suppression_doc should document sh || true'
}

# (8) Self-exclusion: scanning only the twin file -> no violations -> skip (2)
$status = Invoke-ScopedStep17 -Ps1Files @($testFile)
if ($status -eq 2) {
  Assert-Pass -Name 'step17_self_exclusion_skips' -Reason 'twin self-exclusion leaves no files -> explicit skip'
} else {
  Assert-Fail -Name 'step17_self_exclusion_skips' -Reason 'twin self-exclusion should leave no files -> explicit skip'
}

Remove-Item -Path $tmpDir -Recurse -Force

if ($script:failed) { exit 1 } else { exit 0 }
