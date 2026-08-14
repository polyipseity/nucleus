function Sync-DirenvConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed direnvrc writable symlink.
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

  # check-suppress:config-method: method 1 (writable symlink) -- direnvrc cross-platform base config.
  $destPath = Join-Path $env:USERPROFILE '.config\direnv\direnvrc'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-NucleusInfo -CommandName 'Sync-DirenvConfig' "removed $destPath"
    }
    return
  }

  $result = Deploy-UserWritableSymlink -Name 'direnv' -User $User -ConfigName 'direnv' -RelativePath 'direnvrc' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-NucleusInfo -CommandName 'direnv' ($result.Message -replace '^direnv: ', '')
}
