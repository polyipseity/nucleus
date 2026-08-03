# Test: step 24 nix-test-eval PS1 must flag tests that are only counted but
# never forced (silent no-ops) and 1-argument deepSeq partial applications,
# while accepting legitimate forcing constructs.

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/24-nix-test-eval.ps1'
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

if ($content -match 'Register-Step -Id "nix-test-eval" -Number 24') {
  Assert-Pass -Name 'step24_ps1_registers' -Reason 'step 24 PS1 registers as nix-test-eval'
} else {
  Assert-Fail -Name 'step24_ps1_registers' -Reason 'step 24 PS1 should register as nix-test-eval'
}

if ($content.Contains('^\s*builtins\.seq\s*\(\s*builtins\.deepSeq')) {
  Assert-Pass -Name 'step24_ps1_partial_application_pattern' -Reason 'step 24 PS1 detects 1-argument builtins.deepSeq partial applications'
} else {
  Assert-Fail -Name 'step24_ps1_partial_application_pattern' -Reason 'step 24 PS1 should detect 1-argument builtins.deepSeq partial applications'
}

if ($content.Contains('builtins\.length\s+')) {
  Assert-Pass -Name 'step24_ps1_length_only_pattern' -Reason 'step 24 PS1 detects builtins.length counting references'
} else {
  Assert-Fail -Name 'step24_ps1_length_only_pattern' -Reason 'step 24 PS1 should detect builtins.length counting references'
}

if ($content.Contains('success = true')) {
  Assert-Pass -Name 'step24_ps1_success_true_pattern' -Reason 'step 24 PS1 looks for success = true'
} else {
  Assert-Fail -Name 'step24_ps1_success_true_pattern' -Reason 'step 24 PS1 should look for success = true'
}

if ($content.Contains('builtins\.(seq|deepSeq|all|filter)')) {
  Assert-Pass -Name 'step24_ps1_forcing_constructs_pattern' -Reason 'step 24 PS1 recognizes legitimate forcing constructs'
} else {
  Assert-Fail -Name 'step24_ps1_forcing_constructs_pattern' -Reason 'step 24 PS1 should recognize legitimate forcing constructs'
}

if ($content -match 'Select-GitIgnored') {
  Assert-Pass -Name 'step24_ps1_gitignore' -Reason 'step 24 PS1 applies the gitignore filter'
} else {
  Assert-Fail -Name 'step24_ps1_gitignore' -Reason 'step 24 PS1 should apply the gitignore filter'
}

if ($content -match 'Split-Path -Leaf \$PSCommandPath') {
  Assert-Pass -Name 'step24_ps1_self_exclusion' -Reason 'step 24 PS1 excludes its own source file'
} else {
  Assert-Fail -Name 'step24_ps1_self_exclusion' -Reason 'step 24 PS1 should exclude its own source file'
}

if ($content -match 'allow-and-deny-lists\.instructions\.md#C7') {
  Assert-Pass -Name 'step24_ps1_category_c' -Reason 'step 24 PS1 registers its self-exclusion in allow-and-deny-lists Category C'
} else {
  Assert-Fail -Name 'step24_ps1_category_c' -Reason 'step 24 PS1 should register its self-exclusion in allow-and-deny-lists Category C'
}

if ($content -match 'tests/\*\.nix' -and $content -match 'lib\.nix') {
  Assert-Pass -Name 'step24_ps1_scope' -Reason 'step 24 PS1 only scans .nix files under tests/ and excludes lib.nix'
} else {
  Assert-Fail -Name 'step24_ps1_scope' -Reason 'step 24 PS1 should only scan .nix files under tests/ and exclude lib.nix'
}

# ---- Behavioral checks (invoke the registered action directly) ----
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/step-runner.ps1')
. $testFile
$action = $script:StepActions[$script:StepActions.Count - 1]

# Reject: 1-argument builtins.deepSeq (partial application) in scoped mode
$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step24-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'tests') -Force > $null
Set-Content -Path (Join-Path -Path $tmpDir -ChildPath 'tests/bad-deepseq.nix') -Value @'
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
}
'@
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('tests/bad-deepseq.nix') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step24_ps1_rejects_1arg_deepseq' -Reason 'step 24 PS1 rejects 1-argument builtins.deepSeq in scoped mode'
} else {
  Assert-Fail -Name 'step24_ps1_rejects_1arg_deepseq' -Reason 'step 24 PS1 should reject 1-argument builtins.deepSeq in scoped mode'
}
Remove-Item -Path $tmpDir -Recurse -Force

# Reject: length-only counting with no forcing construct in scoped mode
$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step24-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'tests') -Force > $null
Set-Content -Path (Join-Path -Path $tmpDir -ChildPath 'tests/bad-length-only.nix') -Value @'
{
  success = true;
  testCount = builtins.length allTests;
}
'@
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('tests/bad-length-only.nix') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step24_ps1_rejects_length_only' -Reason 'step 24 PS1 rejects length-only counting with no forcing construct'
} else {
  Assert-Fail -Name 'step24_ps1_rejects_length_only' -Reason 'step 24 PS1 should reject length-only counting with no forcing construct'
}
Remove-Item -Path $tmpDir -Recurse -Force

# Accept: 2-argument builtins.deepSeq in scoped mode
$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step24-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'tests') -Force > $null
Set-Content -Path (Join-Path -Path $tmpDir -ChildPath 'tests/good-deepseq.nix') -Value @'
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
}
'@
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('tests/good-deepseq.nix') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if (-not $threw) {
  Assert-Pass -Name 'step24_ps1_accepts_2arg_deepseq' -Reason 'step 24 PS1 accepts 2-argument builtins.deepSeq'
} else {
  Assert-Fail -Name 'step24_ps1_accepts_2arg_deepseq' -Reason 'step 24 PS1 should accept 2-argument builtins.deepSeq'
}
Remove-Item -Path $tmpDir -Recurse -Force

# Accept: top-level assert forcing in scoped mode
$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step24-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'tests') -Force > $null
Set-Content -Path (Join-Path -Path $tmpDir -ChildPath 'tests/good-assert.nix') -Value @'
assert builtins.all (t: t == null) allTests;
{
  success = true;
  testCount = builtins.length allTests;
}
'@
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('tests/good-assert.nix') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if (-not $threw) {
  Assert-Pass -Name 'step24_ps1_accepts_top_level_assert' -Reason 'step 24 PS1 accepts top-level assert forcing'
} else {
  Assert-Fail -Name 'step24_ps1_accepts_top_level_assert' -Reason 'step 24 PS1 should accept top-level assert forcing'
}
Remove-Item -Path $tmpDir -Recurse -Force

# Reject: length-only no-op in full mode
$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step24-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'tests') -Force > $null
Set-Content -Path (Join-Path -Path $tmpDir -ChildPath 'tests/bad-full.nix') -Value @'
{
  success = true;
  testCount = builtins.length allTests;
}
'@
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
  Assert-Pass -Name 'step24_ps1_rejects_full_mode' -Reason 'step 24 PS1 rejects length-only no-ops in full mode'
} else {
  Assert-Fail -Name 'step24_ps1_rejects_full_mode' -Reason 'step 24 PS1 should reject length-only no-ops in full mode'
}
Remove-Item -Path $tmpDir -Recurse -Force

# Accept: lib.nix excluded in full mode
$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step24-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'tests') -Force > $null
Set-Content -Path (Join-Path -Path $tmpDir -ChildPath 'tests/lib.nix') -Value @'
{
  success = true;
  testCount = builtins.length allTests;
}
'@
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $false -RepoRoot $tmpDir -PositionalArgs @() > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if (-not $threw) {
  Assert-Pass -Name 'step24_ps1_ignores_lib_nix' -Reason 'step 24 PS1 ignores lib.nix in full mode'
} else {
  Assert-Fail -Name 'step24_ps1_ignores_lib_nix' -Reason 'step 24 PS1 should ignore lib.nix in full mode'
}
Remove-Item -Path $tmpDir -Recurse -Force

if ($script:failed) { exit 1 } else { exit 0 }
