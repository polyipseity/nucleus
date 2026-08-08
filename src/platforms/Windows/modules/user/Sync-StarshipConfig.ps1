function Sync-StarshipConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed starship.toml writable symlink.
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

  $destPath = Join-Path $env:USERPROFILE '.config\starship.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-StarshipConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  $destDir = Split-Path $destPath -Parent
  if (-not (Test-Path -Path $destDir -PathType Container)) {
    New-Item -Path $destDir -ItemType Directory -Force > $null
  }

  $result = Deploy-UserWritableSymlink -Name 'starship' -User $User -ConfigName 'starship' -RelativePath 'starship.toml' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-Output "$($PSStyle.Foreground.Cyan)$($result.Message)$($PSStyle.Reset)"
}
