<#
.SYNOPSIS
  Deploys Windows safe-delete shims (rip.exe copies) and converges the
  PowerShell recycling function.

.DESCRIPTION
  Safe-delete defense for Windows: PowerShell overrides rm/del/rd/erase/ri/
  Remove-Item with a .NET Recycle Bin function (in profile.ps1). For non-PowerShell
  contexts (cmd.exe, Git Bash, scripts, agents), rip.exe shims in
  %USERPROFILE%\.local\bin intercept all deletion commands.

  Layout this function converges:

    <USER root>\bin\rm.exe, del.exe, rd.exe, rmdir.exe, erase.exe, ri.exe
      deployed copies of rip.exe (from Scoop shims dir)
    %USERPROFILE%\.local\bin\rm.exe, del.exe, ...  PATH shims (copies)

.PARAMETER Enabled
  Whether safe-delete shims should be enforced.

.PARAMETER RepoRoot
  Absolute path to the live repository root.

.PARAMETER UserRoot
  Absolute path to the nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

.PARAMETER UserProfile
  Absolute path to the user profile (%USERPROFILE%).
#>

function Sync-SafeDelete {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$UserRoot,

    [Parameter(Mandatory)]
    [string]$UserProfile
  )

  $binDir = Join-Path -Path $UserRoot -ChildPath "bin"
  $shimDir = Join-Path -Path $UserProfile -ChildPath ".local\bin"
  $ripExe = Join-Path -Path (Get-NucleusScoopShimsDir) -ChildPath "rip.exe"

  $shimNames = @("rm.exe", "del.exe", "rd.exe", "rmdir.exe", "erase.exe", "ri.exe")

  # Clink Lua filter for cmd.exe interception
  $clinkDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "clink"
  $clinkLua = Join-Path -Path $clinkDir -ChildPath "safedel.lua"
  $clinkLuaSource = Join-Path -Path $RepoRoot -ChildPath "src\platforms\Windows\modules\user\clink\safedel.lua"

  if (-not $Enabled) {
    foreach ($name in $shimNames) {
      $target = Join-Path -Path $shimDir -ChildPath $name
      if (Test-Path -LiteralPath $target) {
        # check-suppress:suppression_doc: shim may already be absent; idempotent cleanup.
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      }
    }
    if (Test-Path -LiteralPath $clinkLua) {
      # check-suppress:suppression_doc: lua file may already be absent; idempotent cleanup.
      Remove-Item -LiteralPath $clinkLua -Force -ErrorAction SilentlyContinue
    }
    return
  }

  if (-not (Test-Path -LiteralPath $ripExe)) {
    Write-NucleusWarning -CommandName 'Sync-SafeDelete' "rip.exe not found at '$ripExe'; run Invoke-ScoopSetup first"
    return
  }

  # Ensure directories exist
  if (-not (Test-Path -LiteralPath $binDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $binDir -Force > $null
  }
  if (-not (Test-Path -LiteralPath $shimDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $shimDir -Force > $null
  }

  foreach ($name in $shimNames) {
    # Deployed copy in USER root bin
    $deployedPath = Join-Path -Path $binDir -ChildPath $name
    Copy-Item -LiteralPath $ripExe -Destination $deployedPath -Force

    # PATH shim in .local\bin
    $shimPath = Join-Path -Path $shimDir -ChildPath $name
    Copy-Item -LiteralPath $ripExe -Destination $shimPath -Force
  }

  # Deploy clink Lua filter
  if (-not (Test-Path -LiteralPath $clinkDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $clinkDir -Force > $null
  }
  if (Test-Path -LiteralPath $clinkLuaSource) {
    Copy-Item -LiteralPath $clinkLuaSource -Destination $clinkLua -Force
  }
}
