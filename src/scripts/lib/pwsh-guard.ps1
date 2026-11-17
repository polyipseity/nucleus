#Requires -Version 5.1
# pwsh-guard.ps1 - PowerShell version floor guard for nucleus entrypoints.
#
# Dot-source this file and call Assert-NucleusPowerShell from directly invocable
# PowerShell scripts. Module files and sourced libs must not add a standalone
# guard; the sweep test exempts them explicitly.

function Assert-NucleusPowerShell {
  <#
  .SYNOPSIS
    Hard-fails when the running PowerShell is below the required major.minor.
  .PARAMETER Minimum
    Minimum version in "major.minor" form (for example, "7.0").
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Minimum
  )

  $parts = $Minimum.Split('.', 2)
  $minMajor = [int]$parts[0]
  $minMinor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }

  $have = $PSVersionTable.PSVersion
  $haveMajor = [int]$have.Major
  $haveMinor = [int]$have.Minor

  $ok = ($haveMajor -gt $minMajor) -or (($haveMajor -eq $minMajor) -and ($haveMinor -ge $minMinor))
  if ($ok) { return }

  $name = if ($PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) } else { 'script' }
  $msg = @(
    "error: $name requires PowerShell >= $Minimum, but this shell is $have."
    'hint: rerun with PowerShell 7+, for example:'
    '  pwsh -NoProfile -File <script>.ps1'
    '  or install PowerShell 7: https://learn.microsoft.com/powershell/scripting/install/installing-powershell'
  ) -join [Environment]::NewLine
  [Console]::Error.WriteLine($msg)
  exit 1
}
