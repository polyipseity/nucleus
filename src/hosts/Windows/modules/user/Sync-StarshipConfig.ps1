function Sync-StarshipConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed starship.toml writable symlink.

  .DESCRIPTION
    Creates a symbolic link from %USERPROFILE%\.config\starship.toml to
    src\modules\configs\starship.toml in the repository (Method 1).
    Edits in the repo take effect immediately without re-running apply.

  .PARAMETER Enabled
    True applies the managed config. False removes the managed symlink.

  .EXAMPLE
    Sync-StarshipConfig -Enabled:$true

  .EXAMPLE
    Sync-StarshipConfig -Enabled:$false

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must be set by caller.
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled
  )

  $configRelPath = 'src\modules\configs\starship.toml'
  $destPath = Join-Path $env:USERPROFILE '.config\starship.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Host "Sync-StarshipConfig: removed $destPath" -ForegroundColor DarkCyan
    }
    return
  }

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Sync-StarshipConfig: NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 which exports this variable.'
  }

  $sourcePath = Join-Path $repoRoot $configRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Sync-StarshipConfig: source config not found at $sourcePath"
  }

  $destDir = Split-Path $destPath -Parent
  if (-not (Test-Path -Path $destDir -PathType Container)) {
    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
  }

  # Method 1 (writable symlink): remove existing file/symlink and replace with symlink.
  if (Test-Path -Path $destPath) {
    Remove-Item -Path $destPath -Force
  }
  New-Item -Path $destPath -ItemType SymbolicLink -Target $sourcePath -Force | Out-Null
  Write-Host "Sync-StarshipConfig: symlinked $destPath" -ForegroundColor DarkCyan
}
