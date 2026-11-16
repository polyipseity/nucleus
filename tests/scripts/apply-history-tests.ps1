#!/usr/bin/env pwsh
# Tests for src/scripts/lib/apply-history.ps1 (G3 Task 5).
# Run: pwsh -NoProfile -File tests/scripts/apply-history-tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$Lib = Join-Path $RepoRoot 'src\scripts\lib\apply-history.ps1'
if (-not (Test-Path -LiteralPath $Lib)) { $Lib = Join-Path $RepoRoot 'src/scripts/lib/apply-history.ps1' }
. $Lib

$script:Passed = 0
$script:Failed = 0
function Assert-Pass([string]$Name) { $script:Passed++; Write-Output "✓ $Name" }
function Assert-Fail([string]$Name, [string]$Reason) { $script:Failed++; Write-Output "✗ ${Name}: $Reason" }

$tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("apply-history-test-" + [System.Guid]::NewGuid().ToString('N')))
$oldLocalAppData = $env:LOCALAPPDATA
$oldHome = $env:HOME
$oldNucleusUserRoot = $env:NUCLEUS_USER_ROOT
try {
  $env:LOCALAPPDATA = Join-Path $tmp.FullName 'LocalAppData'
  $env:HOME = $tmp.FullName
  $env:NUCLEUS_USER_ROOT = $null
  $cfgDir = Join-Path $env:HOME '.local/state/nucleus'
  $null = New-Item -ItemType Directory -Path $cfgDir -Force # check-suppress:suppression_doc: test setup output not needed

  # 1) default limit and non-git record shape
  if ((Get-ApplyHistoryLimit) -ne 256) {
    Assert-Fail "default applyHistoryLimit is 256" "got $(Get-ApplyHistoryLimit)"
  } else {
    Assert-Pass "default applyHistoryLimit is 256"
  }

  Set-Content -LiteralPath (Join-Path $cfgDir 'config.json') -Value '{"applyHistoryLimit":256}' -Encoding utf8
  $ng = New-Item -ItemType Directory -Path (Join-Path $tmp.FullName 'nongit')
  Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $ng.FullName -HostName TestHost -User testuser
  $path = Get-ApplyHistoryPath
  $rawLines = @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $raw = $rawLines[0]
  $ok = ($rawLines.Count -eq 1 -and
    $raw -match '"version":1' -and
    $raw -match '"result":"success"' -and
    $raw -match '"phase":null' -and
    $raw -match '"host":"TestHost"' -and
    $raw -match '"user":"testuser"' -and
    $raw -match '"commitHash":null' -and
    $raw -match '"branch":null' -and
    $raw -match '"detachedHead":null' -and
    $raw -match '"appliedCommitTag":null' -and
    $raw -match '"lastTagOnBranch":null' -and
    $raw -match '"hasUnstaged":null' -and
    $raw -match '"hasStaged":null' -and
    $raw -match '"hasUntracked":null' -and
    $raw -match '"isDirty":null' -and
    $raw -match '"appliedAt":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"')
  if ($ok) { Assert-Pass "non-git success record has correct shape and null git fields" }
  else { Assert-Fail "non-git success record shape" "raw=[$raw]" }

  # 2) failure record carries phase and reader newest-first/count/json
  Add-ApplyHistoryRecord -Result failure -Phase rebuild -RepoRoot $ng.FullName -HostName TestHost -User testuser
  $json = Get-ApplyHistoryEntriesJson
  $obj = $json | ConvertFrom-Json
  if (@($obj.entries).Count -eq 2 -and $obj.entries[0].result -eq 'failure' -and $obj.entries[0].phase -eq 'rebuild' -and $obj.entries[1].result -eq 'success') {
    Assert-Pass "failure record carries phase and JSON reader is newest-first"
  } else {
    Assert-Fail "failure/newest-first" "json=[$json]"
  }
  $json1 = Get-ApplyHistoryEntriesJson -Count 1
  $obj1 = $json1 | ConvertFrom-Json
  if (@($obj1.entries).Count -eq 1 -and $obj1.entries[0].phase -eq 'rebuild') { Assert-Pass "reader respects Count (newest N)" }
  else { Assert-Fail "reader Count" "json=[$json1]" }

  # 3) human latest and appliedAt formatting
  $human = (Get-ApplyHistoryLatestHuman) -join "`n"
  if ($human -match 'result: failure' -and $human -match 'phase: rebuild' -and $human -match 'appliedAt: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z') {
    Assert-Pass "human latest shows failure/phase and RFC3339 appliedAt"
  } else {
    Assert-Fail "human latest" "human=[$human]"
  }

  # 4) trim positive
  Set-Content -LiteralPath (Join-Path $cfgDir 'config.json') -Value '{"applyHistoryLimit":2}' -Encoding utf8
  Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $ng.FullName -HostName H -User u3
  $lines = @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $last = ($lines[-1] | ConvertFrom-Json)
  if (@($lines).Count -eq 2 -and $last.user -eq 'u3') { Assert-Pass "limit 2 keeps newest 2" }
  else { Assert-Fail "trim positive" "count=$(@($lines).Count) lastUser=$($last.user)" }

  # 5) limit 0 disables writes
  Set-Content -LiteralPath (Join-Path $cfgDir 'config.json') -Value '{"applyHistoryLimit":0}' -Encoding utf8
  Remove-Item -LiteralPath $path -Force
  Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $ng.FullName -HostName H -User u4
  if (-not (Test-Path -LiteralPath $path)) { Assert-Pass "limit 0 disables writes" }
  else { Assert-Fail "limit 0 disables writes" "file exists" }

  # 6) negative unlimited
  Set-Content -LiteralPath (Join-Path $cfgDir 'config.json') -Value '{"applyHistoryLimit":-1}' -Encoding utf8
  Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $ng.FullName -HostName H -User a
  Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $ng.FullName -HostName H -User b
  Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $ng.FullName -HostName H -User c
  $lines = @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if (@($lines).Count -eq 3) { Assert-Pass "negative limit keeps unlimited records" }
  else { Assert-Fail "negative unlimited" "count=$(@($lines).Count)" }

  # 7) corrupt line reporting
  Set-Content -LiteralPath $path -Value @('{"version":1}', 'not-json') -Encoding utf8
  $threw = $false; $msg = ''
  try { $null = Get-ApplyHistoryEntriesJson } catch { $threw = $true; $msg = $_.Exception.Message }
  if ($threw -and $msg -match 'corrupt line 2') { Assert-Pass "corrupt line reported naming line 2" }
  else { Assert-Fail "corrupt line reporting" "threw=$threw msg=[$msg]" }

  # 8) empty/missing
  Remove-Item -LiteralPath $path -Force
  $ej = Get-ApplyHistoryEntriesJson
  $eo = $ej | ConvertFrom-Json
  $h2 = (Get-ApplyHistoryLatestHuman) -join "`n"
  if (@($eo.entries).Count -eq 0 -and $h2 -match 'No apply history yet\.') { Assert-Pass "empty/missing history returns empty JSON and human message" }
  else { Assert-Fail "empty/missing" "json=[$ej] human=[$h2]" }

  # 9) git field derivation
  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) {
    Assert-Fail "git field derivation" "git not found"
  } else {
    $repo = Join-Path $tmp.FullName 'gitrepo'
    $null = New-Item -ItemType Directory -Path $repo -Force # check-suppress:suppression_doc: test setup output not needed
    function Invoke-TestGit { param([string[]]$GitArgs) & git -c user.name='Test User' -c user.email='test@example.com' -c commit.gpgsign=false @GitArgs }
    Set-Content -LiteralPath (Join-Path $cfgDir 'config.json') -Value '{"applyHistoryLimit":256}' -Encoding utf8
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue # check-suppress:suppression_doc: test reset best-effort
    $null = Invoke-TestGit @('-C', $repo, 'init', '-q') # check-suppress:suppression_doc: test setup output not needed
    Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "a" -Encoding utf8
    $null = Invoke-TestGit @('-C', $repo, 'add', 'file.txt') # check-suppress:suppression_doc: test setup output not needed
    $null = Invoke-TestGit @('-C', $repo, 'commit', '-qm', 'init') # check-suppress:suppression_doc: test setup output not needed
    $null = Invoke-TestGit @('-C', $repo, 'tag', '-a', 'v1', '-m', 'v1') # check-suppress:suppression_doc: test setup output not needed
    Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $repo -HostName TestHost -User testuser
    $gjson = Get-ApplyHistoryEntriesJson -Count 1
    $gobj = $gjson | ConvertFrom-Json
    $ge = $gobj.entries[0]
    $gok = ($null -ne $ge.commitHash -and $ge.commitHash -is [string] -and
      ($ge.branch -eq 'master' -or $ge.branch -eq 'main') -and
      $ge.detachedHead -eq $false -and $ge.appliedCommitTag -eq 'v1' -and $ge.lastTagOnBranch -eq 'v1' -and
      $ge.hasUnstaged -eq $false -and $ge.hasStaged -eq $false -and $ge.hasUntracked -eq $false -and $ge.isDirty -eq $false)
    if ($gok) { Assert-Pass "git repo (clean, tagged) records derived fields" }
    else { Assert-Fail "git clean tagged derivation" "json=[$gjson]" }

    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue # check-suppress:suppression_doc: test reset best-effort
    Add-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "b" -Encoding utf8
    $null = Invoke-TestGit @('-C', $repo, 'add', 'file.txt') # check-suppress:suppression_doc: test setup output not needed
    Add-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "c" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repo 'untracked.txt') -Value "u" -Encoding utf8
    Add-ApplyHistoryRecord -Result failure -Phase preflight -RepoRoot $repo -HostName TestHost -User testuser
    $djson = Get-ApplyHistoryEntriesJson -Count 1
    $dobj = $djson | ConvertFrom-Json
    $de = $dobj.entries[0]
    $dok = ($de.hasStaged -eq $true -and $de.hasUnstaged -eq $true -and $de.hasUntracked -eq $true -and $de.isDirty -eq $true -and
      $de.appliedCommitTag -eq 'v1' -and $de.lastTagOnBranch -eq 'v1')
    if ($dok) { Assert-Pass "git repo (dirty staged/unstaged/untracked) records status flags" }
    else { Assert-Fail "git dirty status derivation" "json=[$djson]" }

    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue # check-suppress:suppression_doc: test reset best-effort
    $null = Invoke-TestGit @('-C', $repo, 'add', '-A') # check-suppress:suppression_doc: test setup output not needed
    $null = Invoke-TestGit @('-C', $repo, 'commit', '-qm', 'second') # check-suppress:suppression_doc: test setup output not needed
    $null = Invoke-TestGit @('-C', $repo, 'checkout', '-q', '--detach') # check-suppress:suppression_doc: test setup output not needed
    Add-ApplyHistoryRecord -Result success -Phase $null -RepoRoot $repo -HostName TestHost -User testuser
    $tjson = Get-ApplyHistoryEntriesJson -Count 1
    $tobj = $tjson | ConvertFrom-Json
    $te = $tobj.entries[0]
    $tok = ($te.detachedHead -eq $true -and $null -eq $te.appliedCommitTag -and $te.lastTagOnBranch -eq 'v1' -and $te.isDirty -eq $false)
    if ($tok) { Assert-Pass "git repo (detached HEAD, untagged commit) records detached/tag fields" }
    else { Assert-Fail "git detached/untagged derivation" "json=[$tjson]" }
  }

} finally {
  $env:LOCALAPPDATA = $oldLocalAppData
  $env:HOME = $oldHome
  $env:NUCLEUS_USER_ROOT = $oldNucleusUserRoot
  Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ""
if ($script:Failed -gt 0) {
  Write-Output "$($script:Passed) passed, $($script:Failed) failed"
} else {
  Write-Output "$($script:Passed) passed"
}
Write-Output "# nucleus-tally passed=$($script:Passed) failed=$($script:Failed)"
if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
