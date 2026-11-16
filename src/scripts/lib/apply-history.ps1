# Apply history (append-only JSONL) writer/reader helpers for PowerShell.
#Requires -Version 5.1

Set-StrictMode -Version Latest

function Get-ApplyHistoryConfigFile {
  [CmdletBinding()]
  param()
  $homeDir = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { $HOME }
  Join-Path -Path $homeDir -ChildPath ".local/state/nucleus/config.json"
}

function Get-ApplyHistoryLimit {
  [CmdletBinding()]
  param()
  $configFile = Get-ApplyHistoryConfigFile
  if (-not (Test-Path -LiteralPath $configFile)) {
    return 256
  }
  try {
    $json = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-Json -ErrorAction Stop
    if ($null -ne $json.applyHistoryLimit) {
      $val = [int]$json.applyHistoryLimit
      return $val
    }
  } catch {
    # fall through
  }
  return 256
}

function Get-ApplyHistoryUserRoot {
  [CmdletBinding()]
  param()
  # Allow explicit override for tests/cross-platform pwsh runs.
  if (-not [string]::IsNullOrWhiteSpace($env:NUCLEUS_USER_ROOT)) {
    return $env:NUCLEUS_USER_ROOT
  }
  # Windows: mirror Get-NucleusUserRoot (%LOCALAPPDATA%\nucleus).
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus')
  }
  # Non-Windows pwsh fallback matching derive_nucleus_user_root semantics.
  $homeDir = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { $HOME }
  if ($IsMacOS) {
    return (Join-Path -Path $homeDir -ChildPath 'Library/Application Support/nucleus')
  }
  return (Join-Path -Path $homeDir -ChildPath '.local/share/nucleus')
}

function Get-ApplyHistoryPath {
  [CmdletBinding()]
  param()
  Join-Path -Path (Get-ApplyHistoryUserRoot) -ChildPath 'state\apply\history.jsonl'
}

function Get-ApplyHistoryNowRfc3339Utc {
  [CmdletBinding()]
  param()
  [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function Get-ApplyHistoryGitFields {
  [CmdletBinding()]
  param(
    [string]$RepoRoot
  )
  $fields = @{
    commitHash = $null
    branch = $null
    detachedHead = $null
    appliedCommitTag = $null
    lastTagOnBranch = $null
    hasUnstaged = $null
    hasStaged = $null
    hasUntracked = $null
    isDirty = $null
  }
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) {
    return $fields
  }
  $gitExe = Get-Command git -ErrorAction SilentlyContinue # check-suppress:suppression_doc: git is optional for non-git roots
  if (-not $gitExe) { return $fields }
  try {
    $inside = & git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null # check-suppress:suppression_doc: probe whether repoRoot is a git work tree
    if ($inside -ne 'true') { return $fields }
  } catch {
    return $fields
  }
  try { $fields.commitHash = (& git -C $RepoRoot rev-parse --short HEAD 2>$null) } catch { $fields.commitHash = $null } # check-suppress:suppression_doc: best-effort git field derivation
  if ([string]::IsNullOrWhiteSpace($fields.commitHash)) { $fields.commitHash = $null }
  try { $fields.branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null) } catch { $fields.branch = $null } # check-suppress:suppression_doc: best-effort git field derivation
  if ([string]::IsNullOrWhiteSpace($fields.branch)) { $fields.branch = $null }
  try {
    $null = & git -C $RepoRoot symbolic-ref -q HEAD 2>$null # check-suppress:suppression_doc: exit code indicates detached HEAD
    if ($LASTEXITCODE -eq 0) { $fields.detachedHead = $false } else { $fields.detachedHead = $true }
  } catch { $fields.detachedHead = $true }

  try {
    $tag = (& git -C $RepoRoot tag --points-at HEAD --sort=-creatordate 2>$null | Select-Object -First 1) # check-suppress:suppression_doc: no tag at HEAD is not an error
    if (-not [string]::IsNullOrWhiteSpace($tag)) { $fields.appliedCommitTag = $tag } else { $fields.appliedCommitTag = $null }
  } catch { $fields.appliedCommitTag = $null }
  try {
    $lasttag = (& git -C $RepoRoot describe --tags --abbrev=0 2>$null) # check-suppress:suppression_doc: no reachable tag is not an error
    if (-not [string]::IsNullOrWhiteSpace($lasttag)) { $fields.lastTagOnBranch = $lasttag } else { $fields.lastTagOnBranch = $null }
  } catch { $fields.lastTagOnBranch = $null }

  $porcelain = & git -C $RepoRoot status --porcelain 2>$null # check-suppress:suppression_doc: best-effort working tree status parsing
  $fields.hasUnstaged = $false
  $fields.hasStaged = $false
  $fields.hasUntracked = $false
  if ($porcelain) {
    foreach ($line in ($porcelain -split "`r?`n")) {
      if ([string]::IsNullOrEmpty($line)) { continue }
      if ($line.StartsWith('??')) {
        $fields.hasUntracked = $true
      } else {
        if ($line.Length -ge 2) {
          $x = $line[0]
          $y = $line[1]
          if ($x -ne ' ' -and $x -ne '?') { $fields.hasStaged = $true }
          if ($y -ne ' ') { $fields.hasUnstaged = $true }
        }
      }
    }
  }
  $fields.isDirty = ($fields.hasUnstaged -or $fields.hasStaged -or $fields.hasUntracked)
  return $fields
}

function Add-ApplyHistoryRecord {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('success','failure')][string]$Result,
    [AllowNull()][AllowEmptyString()][string]$Phase,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][string]$User
  )
  $limit = Get-ApplyHistoryLimit
  if ($limit -eq 0) { return }

  $histPath = Get-ApplyHistoryPath
  $histDir = Split-Path -Parent $histPath
  if (-not (Test-Path -LiteralPath $histDir)) {
    $null = New-Item -ItemType Directory -Path $histDir -Force # check-suppress:suppression_doc: directory creation output not needed
  }

  $appliedAt = Get-ApplyHistoryNowRfc3339Utc
  $gitFields = Get-ApplyHistoryGitFields -RepoRoot $RepoRoot

  $phaseVal = $null
  if (-not [string]::IsNullOrWhiteSpace($Phase) -and $Phase -ne 'null') { $phaseVal = $Phase }

  $obj = [ordered]@{
    version = 1
    appliedAt = $appliedAt
    result = $Result
    phase = $phaseVal
    host = $HostName
    user = $User
    repoRoot = $RepoRoot
    commitHash = $gitFields.commitHash
    branch = $gitFields.branch
    detachedHead = $gitFields.detachedHead
    appliedCommitTag = $gitFields.appliedCommitTag
    lastTagOnBranch = $gitFields.lastTagOnBranch
    hasUnstaged = $gitFields.hasUnstaged
    hasStaged = $gitFields.hasStaged
    hasUntracked = $gitFields.hasUntracked
    isDirty = $gitFields.isDirty
  }
  $line = ($obj | ConvertTo-Json -Compress -Depth 5)

  $existing = @()
  if (Test-Path -LiteralPath $histPath) {
    # check-suppress:suppression_doc: unreadable or missing history treated as empty before append
    $existing = @(Get-Content -LiteralPath $histPath -ErrorAction SilentlyContinue)
  }
  $allLines = @(@($existing + $line) | Where-Object { $null -ne $_ -and $_ -ne '' })

  if ($limit -gt 0 -and @($allLines).Count -gt $limit) {
    $arr = @($allLines)
    $allLines = $arr[($arr.Count - $limit)..($arr.Count - 1)]
  }

  $origMode = $null
  $origAcl = $null
  $hadExisting = Test-Path -LiteralPath $histPath
  if ($hadExisting) {
    try {
      if ($IsWindows) {
        $origAcl = Get-Acl -LiteralPath $histPath -ErrorAction Stop
      } else {
        $origMode = [System.IO.File]::GetUnixFileMode($histPath)
      }
    } catch {
      # Best-effort preservation.
    }
  }

  $tmp = Join-Path -Path $histDir -ChildPath (".history.$([System.Guid]::NewGuid().ToString('N')).tmp")
  try {
    Set-Content -LiteralPath $tmp -Value ($allLines -join "`n") -Encoding utf8 -NoNewline
    Add-Content -LiteralPath $tmp -Value "" -Encoding utf8
    if ($hadExisting) {
      try {
        if ($IsWindows -and $null -ne $origAcl) {
          Set-Acl -LiteralPath $tmp -AclObject $origAcl -ErrorAction Stop
        } elseif (-not $IsWindows -and $null -ne $origMode) {
          [System.IO.File]::SetUnixFileMode($tmp, $origMode)
        }
      } catch {
        # Best-effort preservation.
      }
    }
    Move-Item -LiteralPath $tmp -Destination $histPath -Force
  } finally {
    if (Test-Path -LiteralPath $tmp) {
      # check-suppress:suppression_doc: best-effort temp file cleanup
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-ApplyHistoryEntriesJson {
  [CmdletBinding()]
  param([int]$Count = 0)
  $histPath = Get-ApplyHistoryPath
  if (-not (Test-Path -LiteralPath $histPath)) {
    return '{"version":1,"entries":[]}'
  }
  # check-suppress:suppression_doc: unreadable history treated as empty by caller-visible read path
  $lines = @(Get-Content -LiteralPath $histPath -ErrorAction SilentlyContinue)
  if (@($lines).Count -eq 0) {
    return '{"version":1,"entries":[]}'
  }
  $entries = @()
  $lineNo = 0
  foreach ($ln in $lines) {
    $lineNo++
    if ([string]::IsNullOrWhiteSpace($ln)) {
      throw "apply-history: corrupt line $lineNo`: empty line"
    }
    try {
      $null = $ln | ConvertFrom-Json -ErrorAction Stop # check-suppress:suppression_doc: validate JSON and discard parsed object
    } catch {
      throw "apply-history: corrupt line $lineNo`: invalid JSON"
    }
    $entries += $ln
  }
  if ($Count -gt 0 -and @($entries).Count -gt $Count) {
    $arr = @($entries)
    $entries = $arr[($arr.Count - $Count)..($arr.Count - 1)]
  }
  # newest first
  [array]::Reverse($entries)
  $joined = ($entries -join ",")
  return "{`"version`":1,`"entries`":[$joined]}"
}

function Get-ApplyHistoryLatestHuman {
  [CmdletBinding()]
  param()
  try {
    $json = Get-ApplyHistoryEntriesJson -Count 1
  } catch {
    throw $_
  }
  $obj = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  if (@($obj.entries).Count -eq 0) {
    Write-Output "No apply history yet."
    return
  }
  $e = $obj.entries[0]
  foreach ($k in @('result','phase','appliedAt','host','user','repoRoot','commitHash','branch','detachedHead','appliedCommitTag','lastTagOnBranch','hasUnstaged','hasStaged','hasUntracked','isDirty')) {
    $v = $e[$k]
    if ($null -eq $v) {
      Write-Output "${k}: null"
    } elseif ($k -eq 'appliedAt' -and $v -is [DateTime]) {
      Write-Output "${k}: $($v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
    } elseif ($k -eq 'appliedAt' -and $v -is [DateTimeOffset]) {
      Write-Output "${k}: $($v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
    } else {
      Write-Output "${k}: $v"
    }
  }
}
