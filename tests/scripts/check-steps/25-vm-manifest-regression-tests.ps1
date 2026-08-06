# Test: step 25 vm-manifest-regression PS1 must flag manifest-contract regressions
# (byte-count refs, binary literals, hard-coded ports, KB/KiB, mib/gib
# identifiers) and accept the sanctioned adapter sites.

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/25-vm-manifest-regression.ps1'
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

if ($content -match 'Register-Step -Id "vm-manifest-regression" -Number 25') {
  Assert-Pass -Name 'step25_ps1_registers' -Reason 'step 25 PS1 registers as vm-manifest-regression'
} else {
  Assert-Fail -Name 'step25_ps1_registers' -Reason 'step 25 PS1 should register as vm-manifest-regression'
}

if ($content.Contains('\.ramBytes|\.diskBytes|"ramBytes"|"diskBytes"')) {
  Assert-Pass -Name 'step25_ps1_g1' -Reason 'step 25 PS1 detects ramBytes/diskBytes property refs'
} else {
  Assert-Fail -Name 'step25_ps1_g1' -Reason 'step 25 PS1 should detect ramBytes/diskBytes property refs'
}

if ($content -match '524288\|536870912\|1073741824') {
  Assert-Pass -Name 'step25_ps1_g2' -Reason 'step 25 PS1 detects binary GiB literals'
} else {
  Assert-Fail -Name 'step25_ps1_g2' -Reason 'step 25 PS1 should detect binary GiB literals'
}

if ($content -match '1048576') {
  Assert-Pass -Name 'step25_ps1_g3' -Reason 'step 25 PS1 detects the MiB literal 1048576'
} else {
  Assert-Fail -Name 'step25_ps1_g3' -Reason 'step 25 PS1 should detect the MiB literal 1048576'
}

if ($content -match 'hostfwd=tcp::') {
  Assert-Pass -Name 'step25_ps1_g5' -Reason 'step 25 PS1 detects hard-coded hostfwd ports'
} else {
  Assert-Fail -Name 'step25_ps1_g5' -Reason 'step 25 PS1 should detect hard-coded hostfwd ports'
}

if ($content -match 'KB\(\[\^A-Za-z\]') {
  Assert-Pass -Name 'step25_ps1_g6' -Reason 'step 25 PS1 detects invalid KB/KiB suffix forms'
} else {
  Assert-Fail -Name 'step25_ps1_g6' -Reason 'step 25 PS1 should detect invalid KB/KiB suffix forms'
}

if ($content -match 'mib\|gib') {
  Assert-Pass -Name 'step25_ps1_g7' -Reason 'step 25 PS1 detects unit-in-identifier names (mib/gib)'
} else {
  Assert-Fail -Name 'step25_ps1_g7' -Reason 'step 25 PS1 should detect unit-in-identifier names (mib/gib)'
}

if ($content -match 'size\.sh' -and $content -match 'SizeStrings\.ps1' -and $content -match 'size\.nix') {
  Assert-Pass -Name 'step25_ps1_parser_exclusions' -Reason 'step 25 PS1 excludes the three size parser files'
} else {
  Assert-Fail -Name 'step25_ps1_parser_exclusions' -Reason 'step 25 PS1 should exclude the three size parser files'
}

if ($content -match '25-vm-manifest-regression\.sh') {
  Assert-Pass -Name 'step25_ps1_self_exclusion' -Reason 'step 25 PS1 excludes both of its own source files'
} else {
  Assert-Fail -Name 'step25_ps1_self_exclusion' -Reason 'step 25 PS1 should exclude both of its own source files'
}

if ($content -match 'Select-GitIgnored') {
  Assert-Pass -Name 'step25_ps1_gitignore' -Reason 'step 25 PS1 applies the gitignore filter'
} else {
  Assert-Fail -Name 'step25_ps1_gitignore' -Reason 'step 25 PS1 should apply the gitignore filter'
}

if ($content -match 'src/\*' -and $content -match 'scripts/\*') {
  Assert-Pass -Name 'step25_ps1_scope' -Reason 'step 25 PS1 only scans src/ and scripts/ in scoped mode'
} else {
  Assert-Fail -Name 'step25_ps1_scope' -Reason 'step 25 PS1 should only scan src/ and scripts/ in scoped mode'
}

# ---- Behavioral checks (invoke the registered action directly) ----
. (Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/step-runner.ps1')
. $testFile
$action = $script:StepActions[$script:StepActions.Count - 1]

$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-step25-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'src') -Force > $null
New-Item -ItemType Directory -Path (Join-Path -Path $tmpDir -ChildPath 'src/scripts') -Force > $null

# Reject: .ramBytes ref in a .ps1 file under src/ (G1, scoped mode)
$g1Fixture = Join-Path -Path $tmpDir -ChildPath 'src/fixture.ps1'
Set-Content -Path $g1Fixture -Value 'vm.ramBytes = 8000000000'
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
  Assert-Pass -Name 'step25_ps1_rejects_rambytes' -Reason 'step 25 PS1 rejects .ramBytes in scoped mode'
} else {
  Assert-Fail -Name 'step25_ps1_rejects_rambytes' -Reason 'step 25 PS1 should reject .ramBytes in scoped mode'
}

# Reject: 1073741824 outside the size parsers (G2, scoped mode)
$g2Fixture = Join-Path -Path $tmpDir -ChildPath 'src/scripts/fixture.sh'
Set-Content -Path $g2Fixture -Value 'x = 1073741824'
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('src/scripts/fixture.sh') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step25_ps1_rejects_gib_literal' -Reason 'step 25 PS1 rejects 1073741824 outside the size parsers'
} else {
  Assert-Fail -Name 'step25_ps1_rejects_gib_literal' -Reason 'step 25 PS1 should reject 1073741824 outside the size parsers'
}

# Reject: invalid KB suffix (G6, scoped mode)
$g6Fixture = Join-Path -Path $tmpDir -ChildPath 'src/kb.nix'
Set-Content -Path $g6Fixture -Value 'size = 8KB'
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('src/kb.nix') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step25_ps1_rejects_kb' -Reason 'step 25 PS1 rejects the invalid KB suffix'
} else {
  Assert-Fail -Name 'step25_ps1_rejects_kb' -Reason 'step 25 PS1 should reject the invalid KB suffix'
}

# Reject: new *_gib identifier (G7, scoped mode)
$g7Fixture = Join-Path -Path $tmpDir -ChildPath 'src/foo.sh'
Set-Content -Path $g7Fixture -Value 'foo_gib = 1'
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('src/foo.sh') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if ($threw) {
  Assert-Pass -Name 'step25_ps1_rejects_identifier' -Reason 'step 25 PS1 rejects a new *_gib identifier'
} else {
  Assert-Fail -Name 'step25_ps1_rejects_identifier' -Reason 'step 25 PS1 should reject a new *_gib identifier'
}

# Accept: sanctioned adapter/parser-adjacent content must NOT be flagged
$goodFixture = Join-Path -Path $tmpDir -ChildPath 'src/scripts/good.sh'
Set-Content -Path $goodFixture -Value @'
_mem_gib="$(( (_ram_bytes + 1073741823) / 1073741824 ))"
KiB available, requires
'@
$threw = $false
try {
  Push-Location $tmpDir
  & $action -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('src/scripts/good.sh') > $null
} catch {
  $threw = $true
} finally {
  Pop-Location
}
if (-not $threw) {
  Assert-Pass -Name 'step25_ps1_accepts_sanctioned' -Reason 'step 25 PS1 accepts sanctioned adapter content'
} else {
  Assert-Fail -Name 'step25_ps1_accepts_sanctioned' -Reason 'step 25 PS1 should accept sanctioned adapter content'
}

# Reject: 8KiB in full mode
$fullFixture = Join-Path -Path $tmpDir -ChildPath 'src/full.nix'
Set-Content -Path $fullFixture -Value 'value = 8KiB'
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
  Assert-Pass -Name 'step25_ps1_rejects_full' -Reason 'step 25 PS1 rejects 8KiB in full mode'
} else {
  Assert-Fail -Name 'step25_ps1_rejects_full' -Reason 'step 25 PS1 should reject 8KiB in full mode'
}

Remove-Item -Path $tmpDir -Recurse -Force

if ($script:failed) { exit 1 } else { exit 0 }
