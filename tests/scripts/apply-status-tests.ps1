#!/usr/bin/env pwsh
# Tests for nucleus-apply status CLI behavior (G3 Task 7, Windows scripts/apply.ps1).
# Run: pwsh -NoProfile -File tests/scripts/apply-status-tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$ApplyPs1 = Join-Path $RepoRoot 'scripts\apply.ps1'
if (-not (Test-Path -LiteralPath $ApplyPs1)) { $ApplyPs1 = Join-Path $RepoRoot 'scripts/apply.ps1' }

$script:Passed = 0
$script:Failed = 0
function Assert-Pass([string]$Name) { $script:Passed++; Write-Output "✓ $Name" }
function Assert-Fail([string]$Name, [string]$Reason) { $script:Failed++; Write-Output "✗ ${Name}: $Reason" }

function New-TestRoot {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-status-test-" + [System.Guid]::NewGuid().ToString('N'))
  if ($PSCmdlet.ShouldProcess($root, 'Create test root directory')) {
    $null = New-Item -ItemType Directory -Path $root -Force # check-suppress:suppression_doc: test setup output not needed
  }
  return $root
}

function Get-HistoryPath([string]$Root) {
  Join-Path $Root 'user-root\state\apply\history.jsonl'
}

function Write-TestEntry([string]$Root, [string]$User, [string]$Result, $Phase) {
  $path = Get-HistoryPath $Root
  $dir = Split-Path -Parent $path
  $null = New-Item -ItemType Directory -Path $dir -Force # check-suppress:suppression_doc: test setup output not needed
  $phaseVal = $null
  if ($null -ne $Phase -and $Phase -ne 'null') { $phaseVal = $Phase }
  $obj = [ordered]@{
    version = 1
    appliedAt = '2026-01-01T00:00:00.000Z'
    result = $Result
    phase = $phaseVal
    host = 'TestHost'
    user = $User
    repoRoot = '/repo'
    commitHash = 'abc1234'
    branch = 'main'
    detachedHead = $false
    appliedCommitTag = $null
    lastTagOnBranch = 'v1.0.0'
    hasUnstaged = $false
    hasStaged = $false
    hasUntracked = $false
    isDirty = $false
  }
  $line = ($obj | ConvertTo-Json -Compress -Depth 5)
  Add-Content -LiteralPath $path -Value $line -Encoding utf8
}

function Invoke-Status {
  param([string]$Root, [string[]]$StatusArgs)
  $oldHome = $env:HOME
  $oldNucleusUserRoot = $env:NUCLEUS_USER_ROOT
  $oldLocalAppData = $env:LOCALAPPDATA
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $env:HOME = Join-Path $Root 'home'
    $env:NUCLEUS_USER_ROOT = Join-Path $Root 'user-root'
    $env:LOCALAPPDATA = Join-Path $Root 'LocalAppData'
    $null = New-Item -ItemType Directory -Path $env:HOME -Force # check-suppress:suppression_doc: test setup output not needed
    $null = New-Item -ItemType Directory -Path $env:NUCLEUS_USER_ROOT -Force # check-suppress:suppression_doc: test setup output not needed
    $null = New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force # check-suppress:suppression_doc: test setup output not needed
    $invokeArgs = @('-NoProfile', '-File', $ApplyPs1, 'status') + @($StatusArgs)
    # Quote args for Start-Process -ArgumentList string form to handle paths with spaces.
    $argString = ($invokeArgs | ForEach-Object {
      $a = [string]$_
      if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }) -join ' '
    $p = Start-Process -FilePath 'pwsh' -ArgumentList $argString -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $script:LAST_RC = $p.ExitCode
    $script:LAST_OUT = if (Test-Path -LiteralPath $outFile) { (Get-Content -Raw -LiteralPath $outFile) } else { '' }
    $script:LAST_ERR = if (Test-Path -LiteralPath $errFile) { (Get-Content -Raw -LiteralPath $errFile) } else { '' }
  } finally {
    $env:HOME = $oldHome
    $env:NUCLEUS_USER_ROOT = $oldNucleusUserRoot
    $env:LOCALAPPDATA = $oldLocalAppData
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue # check-suppress:suppression_doc: temp file cleanup best-effort
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue # check-suppress:suppression_doc: temp file cleanup best-effort
  }
}

# 1) missing/empty
$root = New-TestRoot
try {
  Invoke-Status -Root $root -StatusArgs @()
  if ($script:LAST_RC -eq 0 -and $script:LAST_OUT -match 'No apply history yet\.') {
    Assert-Pass "status on missing history exits 0 with humanized message"
  } else {
    Assert-Fail "status on missing history" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]"
  }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

$root = New-TestRoot
try {
  Invoke-Status -Root $root -StatusArgs @('--json')
  $ok = $false
  if ($script:LAST_RC -eq 0) {
    try {
      $obj = $script:LAST_OUT | ConvertFrom-Json -ErrorAction Stop
      $ok = ($obj.version -eq 1 -and @($obj.entries).Count -eq 0)
    } catch { $ok = $false }
  }
  if ($ok) { Assert-Pass "status --json on empty history returns empty entries" }
  else { Assert-Fail "status --json on empty history" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]" }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

# 2) json shape/default count (latest)
$root = New-TestRoot
try {
  Write-TestEntry -Root $root -User 'u1' -Result 'success' -Phase 'null'
  Write-TestEntry -Root $root -User 'u2' -Result 'failure' -Phase 'rebuild'
  Invoke-Status -Root $root -StatusArgs @('--json')
  $ok = $false
  if ($script:LAST_RC -eq 0) {
    try {
      $obj = $script:LAST_OUT | ConvertFrom-Json -ErrorAction Stop
      $ok = ($obj.version -eq 1 -and @($obj.entries).Count -eq 1 -and $obj.entries[0].user -eq 'u2' -and $obj.entries[0].result -eq 'failure' -and $obj.entries[0].phase -eq 'rebuild')
    } catch { $ok = $false }
  }
  if ($ok) { Assert-Pass "status --json returns latest entry with versioned shape" }
  else { Assert-Fail "status --json latest shape" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]" }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

# 3) --history N newest-first/count human and json
$root = New-TestRoot
try {
  Write-TestEntry -Root $root -User 'first' -Result 'success' -Phase 'null'
  Write-TestEntry -Root $root -User 'second' -Result 'success' -Phase 'null'
  Write-TestEntry -Root $root -User 'third' -Result 'failure' -Phase 'post-apply'
  Invoke-Status -Root $root -StatusArgs @('--history', '2')
  $thirdIdx = $script:LAST_OUT.IndexOf('user: third')
  $secondIdx = $script:LAST_OUT.IndexOf('user: second')
  $firstIdx = $script:LAST_OUT.IndexOf('user: first')
  if ($script:LAST_RC -eq 0 -and $thirdIdx -ge 0 -and $secondIdx -gt $thirdIdx -and $firstIdx -lt 0) {
    Assert-Pass "status --history N prints N newest records most recent first"
  } else {
    Assert-Fail "status --history N human" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]"
  }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

$root = New-TestRoot
try {
  Write-TestEntry -Root $root -User 'first' -Result 'success' -Phase 'null'
  Write-TestEntry -Root $root -User 'second' -Result 'success' -Phase 'null'
  Write-TestEntry -Root $root -User 'third' -Result 'failure' -Phase 'post-apply'
  Invoke-Status -Root $root -StatusArgs @('--history', '2', '--json')
  $ok = $false
  if ($script:LAST_RC -eq 0) {
    try {
      $obj = $script:LAST_OUT | ConvertFrom-Json -ErrorAction Stop
      $ok = (@($obj.entries).Count -eq 2 -and $obj.entries[0].user -eq 'third' -and $obj.entries[1].user -eq 'second')
    } catch { $ok = $false }
  }
  if ($ok) { Assert-Pass "status --history N --json returns N newest entries in order" }
  else { Assert-Fail "status --history N --json" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]" }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

# 4) corrupt line
$root = New-TestRoot
try {
  $path = Get-HistoryPath $root
  $dir = Split-Path -Parent $path
  $null = New-Item -ItemType Directory -Path $dir -Force # check-suppress:suppression_doc: test setup output not needed
  Set-Content -LiteralPath $path -Value @('{"version":1,"result":"success"}', 'not-json') -Encoding utf8
  Invoke-Status -Root $root -StatusArgs @()
  $combined = "$($script:LAST_OUT)`n$($script:LAST_ERR)"
  if ($script:LAST_RC -ne 0 -and $combined -match 'corrupt line 2') {
    Assert-Pass "corrupt line reported naming line number with non-zero exit"
  } else {
    Assert-Fail "corrupt line error" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]"
  }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

# 5) human latest default
$root = New-TestRoot
try {
  Write-TestEntry -Root $root -User 'old' -Result 'success' -Phase 'null'
  Write-TestEntry -Root $root -User 'new' -Result 'success' -Phase 'null'
  Invoke-Status -Root $root -StatusArgs @()
  if ($script:LAST_RC -eq 0 -and $script:LAST_OUT -match 'user: new' -and $script:LAST_OUT -notmatch 'user: old') {
    Assert-Pass "status with no args shows newest record human-readably"
  } else {
    Assert-Fail "status default human latest" "rc=$($script:LAST_RC) out=[$($script:LAST_OUT)] err=[$($script:LAST_ERR)]"
  }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: test cleanup best-effort

Write-Output ""
if ($script:Failed -gt 0) {
  Write-Output "$($script:Passed) passed, $($script:Failed) failed"
} else {
  Write-Output "$($script:Passed) passed"
}
Write-Output "# nucleus-tally passed=$($script:Passed) failed=$($script:Failed)"
if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
