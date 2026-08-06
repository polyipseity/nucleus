function Sync-StarshipConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed starship.toml writable symlink.

  .DESCRIPTION
    Creates a symbolic link from %USERPROFILE%\.config\starship.toml to the
    per-user overlay starship.toml in the repository (Method 1).
    Edits in the repo take effect immediately without re-running apply.

  .PARAMETER Enabled
    True applies the managed config. False removes the managed symlink.

  .PARAMETER User
    Username for overlay resolution under src/users/.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Sync-StarshipConfig -Enabled:$true -User 'polyipseity' -RepoRoot $env:NUCLEUS_REPO_ROOT

  .EXAMPLE
    Sync-StarshipConfig -Enabled:$false -User 'polyipseity' -RepoRoot $env:NUCLEUS_REPO_ROOT

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must be set by caller.
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

  $destPath = Join-Path $env:USERPROFILE '.config\starship.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-StarshipConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw 'Sync-StarshipConfig: RepoRoot is not set. Run via apply.ps1 which exports NUCLEUS_REPO_ROOT.'
  }

  $sourcePath = Resolve-UserConfigFile -User $User -ConfigName 'starship' -RelativePath 'starship.toml' -RepoRoot $RepoRoot
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Sync-StarshipConfig: source config not found at $sourcePath"
  }

  $destDir = Split-Path $destPath -Parent
  if (-not (Test-Path -Path $destDir -PathType Container)) {
    New-Item -Path $destDir -ItemType Directory -Force > $null
  }

  # check-suppress:config-method: method 1 (writable symlink) -- remove existing file/symlink and replace with symlink.
  if (Test-Path -Path $destPath) {
    Remove-Item -Path $destPath -Force
  }
  New-Item -Path $destPath -ItemType SymbolicLink -Target $sourcePath -Force > $null
  Write-Output "$($PSStyle.Foreground.Cyan)Sync-StarshipConfig: symlinked $destPath$($PSStyle.Reset)"
}
