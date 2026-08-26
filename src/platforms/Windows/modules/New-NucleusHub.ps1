function New-NucleusHub {
  <#
  .SYNOPSIS
    Create the per-user ~/.nucleus hub for a managed Windows user.

  .DESCRIPTION
    Mirrors mkNucleusHub in src/modules/lib/nucleus-roots.nix. Creates a
    %USERPROFILE%\.nucleus hub directory whose `user` junction points at the
    USER root (%LOCALAPPDATA%\nucleus) and whose `system` junction points at
    the SYSTEM root (%ProgramData%\nucleus).

    Directory junctions are used (not symbolic links) because both targets are
    local, same-volume directories and junctions require no symlink privilege.

  .PARAMETER UserHome
    Absolute path to the target user's home directory (e.g. C:\Users\admin).
    The hub is created at Join-Path $UserHome '.nucleus'.

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; throws on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$UserHome
  )

  $ErrorActionPreference = 'Stop'

  $hubDir = Join-Path -Path $UserHome -ChildPath '.nucleus'
  $userRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus'
  $systemRoot = Join-Path -Path $env:ProgramData -ChildPath 'nucleus'

  if (-not (Test-Path -Path $hubDir -PathType Container)) {
    New-Item -Path $hubDir -ItemType Directory -Force > $null
  }

  # Junction user -> USER root. Recreate if it points elsewhere.
  $userLink = Join-Path -Path $hubDir -ChildPath 'user'
  if (Test-Path -LiteralPath $userLink) {
    $target = (Get-Item -LiteralPath $userLink).Target
    if ($target -ne $userRoot) {
      Remove-Item -LiteralPath $userLink -Force
    }
  }
  if (-not (Test-Path -LiteralPath $userLink)) {
    New-Item -Path $userLink -ItemType Junction -Value $userRoot > $null
  }

  # Junction system -> SYSTEM root.
  $systemLink = Join-Path -Path $hubDir -ChildPath 'system'
  if (Test-Path -LiteralPath $systemLink) {
    $target = (Get-Item -LiteralPath $systemLink).Target
    if ($target -ne $systemRoot) {
      Remove-Item -LiteralPath $systemLink -Force
    }
  }
  if (-not (Test-Path -LiteralPath $systemLink)) {
    New-Item -Path $systemLink -ItemType Junction -Value $systemRoot > $null
  }

  Write-NucleusInfo -CommandName 'New-NucleusHub' "created hub at '$hubDir' (user -> '$userRoot', system -> '$systemRoot')"
}
