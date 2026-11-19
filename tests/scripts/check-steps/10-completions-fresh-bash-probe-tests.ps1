# Test: completions-fresh (check step 10) Windows bash probe helpers (PowerShell).
#
# Behavioral coverage for the extracted bash/path helpers used by the Windows
# completion introspection and provider probes: Windows path conversion to a
# git-bash path, bash --version parsing, >= 5.1 acceptance/rejection, and clear
# requirement errors naming the found version and floor.

#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failCount = 0

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

function Assert-Equal {
  param(
    [string]$Name,
    $Actual,
    $Expected
  )

  if ($Actual -ceq $Expected) {
    Assert-Pass $Name
  } else {
    Assert-Fail $Name "expected [$Expected], got [$Actual]"
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bashProbeLib = Join-Path $repoRoot 'src/scripts/lib/completions-bash-probe.ps1'

. $bashProbeLib

foreach ($name in @(
    'ConvertTo-NucleusGitBashPath',
    'Get-NucleusBashVersionString',
    'Test-NucleusBashVersionAtLeast',
    'Get-NucleusBashVersionRequirementError'
  )) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Assert-Fail 'helper exists' "$name not found after dot-sourcing"
    Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
    exit 1
  }
}
Assert-Pass 'bash probe helpers exist after dot-sourcing'

# Path conversion: Windows drive path -> git-bash path (/d/... form), backslashes normalized.
Assert-Equal -Name 'converts Windows drive path to git-bash path' `
  -Actual (ConvertTo-NucleusGitBashPath -Path 'D:\a\nucleus\nucleus\scripts\svc.sh') `
  -Expected '/d/a/nucleus/nucleus/scripts/svc.sh'
Assert-Equal -Name 'converts lowercase drive letter path' `
  -Actual (ConvertTo-NucleusGitBashPath -Path 'c:\repo\scripts\svc.sh') `
  -Expected '/c/repo/scripts/svc.sh'
Assert-Equal -Name 'normalizes backslashes without drive letter' `
  -Actual (ConvertTo-NucleusGitBashPath -Path 'scripts\svc.sh') `
  -Expected 'scripts/svc.sh'
Assert-Equal -Name 'leaves POSIX path unchanged aside from separator normalization' `
  -Actual (ConvertTo-NucleusGitBashPath -Path '/usr/bin/bash') `
  -Expected '/usr/bin/bash'

# Version parsing.
Assert-Equal -Name 'parses GNU bash version string' `
  -Actual (Get-NucleusBashVersionString -VersionOutput 'GNU bash, version 4.4.23(1)-release (x86_64-pc-msys)') `
  -Expected '4.4.23'
Assert-Equal -Name 'parses simple version string' `
  -Actual (Get-NucleusBashVersionString -VersionOutput 'GNU bash, version 5.2.15(1)-release (aarch64-apple-darwin23.0.0)') `
  -Expected '5.2.15'
Assert-Equal -Name 'returns null for unparseable version output' `
  -Actual (Get-NucleusBashVersionString -VersionOutput 'not bash') `
  -Expected $null

# Version floor (>= 5.1).
if (Test-NucleusBashVersionAtLeast -VersionOutput 'GNU bash, version 5.2.15(1)-release') { Assert-Pass 'accepts bash 5.2.15' } else { Assert-Fail 'accepts bash 5.2.15' 'expected >= 5.1' }
if (Test-NucleusBashVersionAtLeast -VersionOutput 'GNU bash, version 5.1.16(1)-release') { Assert-Pass 'accepts bash 5.1.16' } else { Assert-Fail 'accepts bash 5.1.16' 'expected >= 5.1' }
if (-not (Test-NucleusBashVersionAtLeast -VersionOutput 'GNU bash, version 4.4.23(1)-release')) { Assert-Pass 'rejects bash 4.4.23' } else { Assert-Fail 'rejects bash 4.4.23' 'expected < 5.1' }
if (-not (Test-NucleusBashVersionAtLeast -VersionOutput 'GNU bash, version 3.2.57(1)-release')) { Assert-Pass 'rejects bash 3.2.57' } else { Assert-Fail 'rejects bash 3.2.57' 'expected < 5.1' }
if (-not (Test-NucleusBashVersionAtLeast -VersionOutput 'GNU bash, version 5.0.18(1)-release')) { Assert-Pass 'rejects bash 5.0.18' } else { Assert-Fail 'rejects bash 5.0.18' 'expected < 5.1' }
if (-not (Test-NucleusBashVersionAtLeast -VersionOutput 'not bash')) { Assert-Pass 'rejects unparseable bash version' } else { Assert-Fail 'rejects unparseable bash version' 'expected false' }

# Requirement error messages name found version/floor and path.
$okError = Get-NucleusBashVersionRequirementError -VersionOutput 'GNU bash, version 5.2.15(1)-release' -BashPath 'C:\Program Files\Git\bin\bash.exe'
if ($null -eq $okError) { Assert-Pass 'no requirement error for acceptable bash' } else { Assert-Fail 'no requirement error for acceptable bash' "got [$okError]" }

$oldError = Get-NucleusBashVersionRequirementError -VersionOutput 'GNU bash, version 4.4.23(1)-release' -BashPath 'C:\Program Files\Git\bin\bash.exe'
if ($oldError -match '4\.4\.23' -and $oldError -match '5\.1' -and $oldError -match 'C:\\Program Files\\Git\\bin\\bash\.exe') {
  Assert-Pass 'requirement error names found version, floor, and path for old bash'
} else {
  Assert-Fail 'requirement error names found version, floor, and path for old bash' "got [$oldError]"
}

$unknownError = Get-NucleusBashVersionRequirementError -VersionOutput 'mystery shell' -BashPath 'bash'
if ($unknownError -match 'unknown version' -and $unknownError -match '5\.1') {
  Assert-Pass 'requirement error names unknown version and floor'
} else {
  Assert-Fail 'requirement error names unknown version and floor' "got [$unknownError]"
}

Write-Output ''
Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
