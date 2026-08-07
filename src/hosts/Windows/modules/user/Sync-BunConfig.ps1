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
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-BunConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  $result = Deploy-UserWritableSymlink -Name 'bun' -User $User -ConfigName 'bun' -RelativePath 'bunfig.toml' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-Output "$($PSStyle.Foreground.Cyan)$($result.Message)$($PSStyle.Reset)"
}
