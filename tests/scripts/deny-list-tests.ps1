#Requires -Version 7.4
# Tests for gitignore-aware deny-list library functions (Select-GitIgnored).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passCount = 0
$script:failCount = 0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$denyList = Join-Path $repoRoot 'src/scripts/lib/deny-list.ps1'
. $denyList

function Assert-Pass {
  param([string]$Name)
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

function Get-FilteredList {
  param([string[]]$InputPaths)
  $results = foreach ($path in $InputPaths) {
    foreach ($item in @($path | Select-GitIgnored)) {
      $item
    }
  }
  return @($results)
}

Push-Location $repoRoot
try {
  $tracked = Join-Path $repoRoot 'README.md'

  $ignored = @(Get-FilteredList -InputPaths @('result'))
  if ($ignored.Count -eq 0) {
    Assert-Pass 'Select-GitIgnored filters known-ignored path result'
  } else {
    Assert-Fail 'Select-GitIgnored filters known-ignored path result' "got: $($ignored -join ', ')"
  }

  $passed = @(Get-FilteredList -InputPaths @($tracked))
  if ($passed.Count -eq 1 -and $passed[0] -eq $tracked) {
    Assert-Pass 'Select-GitIgnored passes tracked path through'
  } else {
    Assert-Fail 'Select-GitIgnored passes tracked path through' "expected $tracked"
  }

  $batch = @(Get-FilteredList -InputPaths @('result', $tracked, '.direnv/cache'))
  if ($batch.Count -eq 1 -and $batch[0] -eq $tracked) {
    Assert-Pass 'Select-GitIgnored batch keeps tracked and removes ignored'
  } else {
    Assert-Fail 'Select-GitIgnored batch keeps tracked and removes ignored' "got: $($batch -join ', ')"
  }

  # The symlinked fixture (tests/fixtures/user-registry/src/users/default) is a
  # tracked symlink to src/users/default, so a recursive walk yields paths git
  # cannot address. All three paths go through ONE call: git rejects the whole
  # batch, and a per-path call would never produce the failure being pinned.
  $beyondLink = Join-Path $repoRoot 'tests/fixtures/user-registry/src/users/default/discord-music-rpc/config.yaml'
  $symlinkWarnings = @()
  $symlinkBatch = @('result', $tracked, $beyondLink |
    Select-GitIgnored -WarningVariable symlinkWarnings -WarningAction SilentlyContinue)
  if ($symlinkBatch.Count -eq 1 -and $symlinkBatch[0] -eq $tracked) {
    Assert-Pass 'Select-GitIgnored keeps filtering the rest of a batch containing a symlink-escaped path'
  } else {
    Assert-Fail 'Select-GitIgnored keeps filtering the rest of a batch containing a symlink-escaped path' "got: $($symlinkBatch -join ', ')"
  }

  # The pass-through warning already quotes the offending pathspec, so naming the
  # path is not enough to tell the two behaviours apart: the drop has to say so.
  $namedWarning = @($symlinkWarnings | Where-Object {
      $_.Message -match 'dropped' -and $_.Message -match [regex]::Escape($beyondLink) })
  if ($namedWarning.Count -gt 0) {
    Assert-Pass 'Select-GitIgnored warns that it dropped the symlink-escaped path'
  } else {
    Assert-Fail 'Select-GitIgnored warns that it dropped the symlink-escaped path' "warnings: $($symlinkWarnings -join ' | ')"
  }

  $empty = @(Get-FilteredList -InputPaths @(''))
  if ($empty.Count -eq 0) {
    Assert-Pass 'Select-GitIgnored empty input produces empty output'
  } else {
    Assert-Fail 'Select-GitIgnored empty input produces empty output' "got: $($empty -join ', ')"
  }
} finally {
  Pop-Location
}

Write-Output ""
Write-Output "$script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
