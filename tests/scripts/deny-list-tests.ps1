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
