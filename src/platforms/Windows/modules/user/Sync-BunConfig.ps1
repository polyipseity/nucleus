function Sync-BunConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed bunfig.toml writable symlink.
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

  $destPath = Join-Path $env:USERPROFILE '.bunfig.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-NucleusInfo -CommandName 'Sync-BunConfig' "removed $destPath"
    }
    return
  }

  $result = Deploy-UserWritableSymlink -Name 'bun' -User $User -ConfigName 'bun' -RelativePath 'bunfig.toml' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-NucleusInfo -CommandName 'bun' ($result.Message -replace '^bun: ', '')
}
