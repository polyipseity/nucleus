function Sync-UvConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed uv.toml writable symlink.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [string]$User,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  $destDirPath = Join-Path $env:APPDATA 'uv'
  $destPath = Join-Path $destDirPath 'uv.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-NucleusInfo -CommandName 'Sync-UvConfig' "removed $destPath"
    }
    return
  }

  if (-not (Test-Path -Path $destDirPath -PathType Container)) {
    New-Item -Path $destDirPath -ItemType Directory -Force > $null
  }

  $result = Deploy-UserWritableSymlink -Name 'uv' -User $User -ConfigName 'uv' -RelativePath 'uv.toml' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-NucleusInfo -CommandName 'uv' ($result.Message -replace '^uv: ', '')
}
