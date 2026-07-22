function Sync-NextestConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed nextest config.toml writable symlink.

  .DESCRIPTION
    Creates a symbolic link from %USERPROFILE%\.config\nextest\config.toml to
    src\modules\configs\nextest\config.toml in the repository (Method 1).
    Edits in the repo take effect immediately without re-running apply.

  .PARAMETER Enabled
    True applies the managed config. False removes the managed symlink.

  .EXAMPLE
    Sync-NextestConfig -Enabled:$true

  .EXAMPLE
    Sync-NextestConfig -Enabled:$false

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must be set by caller.
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled
  )

  $configRelPath = 'src\modules\configs\nextest\config.toml'
  $destPath = Join-Path $env:USERPROFILE '.config\nextest\config.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-NextestConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Sync-NextestConfig: NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 which exports this variable.'
  }

  $sourcePath = Join-Path $repoRoot $configRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Sync-NextestConfig: source config not found at $sourcePath"
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
  Write-Output "$($PSStyle.Foreground.Cyan)Sync-NextestConfig: symlinked $destPath$($PSStyle.Reset)"
}
