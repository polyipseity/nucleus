function Sync-NextestConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed nextest config.toml writable symlink.
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

  $destPath = Join-Path $env:USERPROFILE '.config\nextest\config.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-NucleusInfo -CommandName 'Sync-NextestConfig' "removed $destPath"
    }
    return
  }

  $destDir = Split-Path $destPath -Parent
  if (-not (Test-Path -Path $destDir -PathType Container)) {
    New-Item -Path $destDir -ItemType Directory -Force > $null
  }

  $result = Deploy-UserWritableSymlink -Name 'nextest' -User $User -ConfigName 'nextest' -RelativePath 'config.toml' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-NucleusInfo -CommandName 'nextest' ($result.Message -replace '^nextest: ', '')
}
