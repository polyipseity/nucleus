# Test: step 23 legacy-token-syntax PS1 must flag {{TOKEN}} and accept __TOKEN__

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/23-legacy-token-syntax.ps1'
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

# ---- Structural checks ----
$content = Get-Content -Path $testFile -Raw

if ($content -match 'Register-Step -Id "legacy-token-syntax" -Number 23') {
  Assert-Pass -Name 'step23_ps1_registers' -Reason 'step 23 PS1 registers as legacy-token-syntax'
} else {
  Assert-Fail -Name 'step23_ps1_registers' -Reason 'step 23 PS1 should register as legacy-token-syntax'
}

if ($content.Contains('\{\{[A-Za-z_]')) {
  Assert-Pass -Name 'step23_ps1_legacy_pattern' -Reason 'step 23 PS1 detects legacy {{TOKEN}} placeholder syntax'
} else {
  Assert-Fail -Name 'step23_ps1_legacy_pattern' -Reason 'step 23 PS1 should detect legacy {{TOKEN}} placeholder syntax'
}

if ($content -match 'Select-GitIgnored') {
  Assert-Pass -Name 'step23_ps1_gitignore' -Reason 'step 23 PS1 applies the gitignore filter'
} else {
  Assert-Fail -Name 'step23_ps1_gitignore' -Reason 'step 23 PS1 should apply the gitignore filter'
}

if ($content -match 'Split-Path -Leaf \$PSCommandPath') {
  Assert-Pass -Name 'step23_ps1_self_exclusion' -Reason 'step 23 PS1 excludes its own source file'
} else {
  Assert-Fail -Name 'step23_ps1_self_exclusion' -Reason 'step 23 PS1 should exclude its own source file'
}

if ($content -match 'allow-and-deny-lists\.instructions\.md#C6') {
  Assert-Pass -Name 'step23_ps1_category_c' -Reason 'step 23 PS1 registers its self-exclusion in allow-and-deny-lists Category C'
} else {
  Assert-Fail -Name 'step23_ps1_category_c' -Reason 'step 23 PS1 should register its self-exclusion in allow-and-deny-lists Category C'
}

if ($content -match 'src/\*' -and $content -match 'scripts/\*') {
  Assert-Pass -Name 'step23_ps1_scope' -Reason 'step 23 PS1 only scans src/ and scripts/ in scoped mode'
} else {
  Assert-Fail -Name 'step23_ps1_scope' -Reason 'step 23 PS1 should only scan src/ and scripts/ in scoped mode'
}

# ---- Behavioral checks (invoke the registered action directly) ----
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/step-runner.ps1')
. $testFile
$action = $script:StepActions[$script:StepActions.Count - 1]

$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step23-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'src') -Force > $null
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'scripts') -Force > $null

# Reject: {{X}} in a .ps1 file under src/ (scoped mode)
$legacyFixture = Join-Path -Path $tmpDir -ChildPath 'src/fixture.ps1'
Set-Content -Path $legacyFixture -Value 'value = {{DEPLOY_ID}}'
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('src/fixture.ps1') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step23_ps1_rejects_legacy' -Reason 'step 23 PS1 rejects {{DEPLOY_ID}} in scoped mode'
} else {
  Assert-Fail -Name 'step23_ps1_rejects_legacy' -Reason 'step 23 PS1 should reject {{DEPLOY_ID}} in scoped mode'
}

# Accept: __X__ in a .ps1 file under src/ (scoped mode)
$okFixture = Join-Path -Path $tmpDir -ChildPath 'src/good.ps1'
Set-Content -Path $okFixture -Value 'value = __DEPLOY_ID__'
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('src/good.ps1') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if (-not $threw) {
  Assert-Pass -Name 'step23_ps1_accepts_double_underscore' -Reason 'step 23 PS1 accepts __DEPLOY_ID__ in scoped mode'
} else {
  Assert-Fail -Name 'step23_ps1_accepts_double_underscore' -Reason 'step 23 PS1 should accept __DEPLOY_ID__ in scoped mode'
}

# Reject: {{X}} in full mode
$fullFixture = Join-Path -Path $tmpDir -ChildPath 'src/full.ps1'
Set-Content -Path $fullFixture -Value 'value = {{LANE_SCOPE}}'
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $false -RepoRoot $tmpDir -PositionalArgs @() > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step23_ps1_rejects_full' -Reason 'step 23 PS1 rejects {{LANE_SCOPE}} in full mode'
} else {
  Assert-Fail -Name 'step23_ps1_rejects_full' -Reason 'step 23 PS1 should reject {{LANE_SCOPE}} in full mode'
}

Remove-Item -Path $tmpDir -Recurse -Force

if ($script:failed) { exit 1 } else { exit 0 }
