function Sync-SrtConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed srt-settings.json writable symlink.

  .DESCRIPTION
    Creates a method-1 (writable) symlink from %USERPROFILE%\.srt-settings.json
    to the resolved user overlay srt/settings.json file. Uses the standard
    user overlay pattern: src/users/default/srt/settings.json as default,
    src/users/<username>/srt/settings.json for per-user overrides.

  .PARAMETER Enabled
    Whether srt settings symlinks should be managed.

  .PARAMETER User
    Username for overlay resolution under src/users/.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository checkout.

  .EXAMPLE
    Sync-SrtConfig -Enabled:$true -User 'admin' -RepoRoot 'C:\Users\admin\repos\nucleus'

  .NOTES
    Exit codes: 0 on success; non-zero on failure
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

  $destPath = Join-Path $env:USERPROFILE '.srt-settings.json'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-NucleusInfo -CommandName 'Sync-SrtConfig' "removed $destPath"
    }
    return
  }

  $result = Deploy-UserWritableSymlink -Name 'srt' -User $User -ConfigName 'srt' -RelativePath 'settings.json' -RepoRoot $RepoRoot -TargetPath $destPath
  Write-NucleusInfo -CommandName 'srt' ($result.Message -replace '^srt: ', '')
}
