function Sync-UvConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed uv.toml writable symlink.

  .DESCRIPTION
    Creates a symbolic link from %APPDATA%\uv\uv.toml to
    src\modules\configs\uv\uv.toml in the repository (Method 1).
    Edits in the repo take effect immediately without re-running apply.
    Mirrors the POSIX shell.nix deployment which places uv.toml at
    $XDG_CONFIG_HOME/uv/uv.toml (~/.config/uv/uv.toml).

  .PARAMETER Enabled
    True applies the managed config. False removes the managed symlink.

  .EXAMPLE
    Sync-UvConfig -Enabled:$true

  .EXAMPLE
    Sync-UvConfig -Enabled:$false

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must be set by caller.
      APPDATA — resolved to the user's AppData\Roaming directory.
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled
  )

  $configRelPath = 'src\modules\configs\uv\uv.toml'
  $destDirPath = Join-Path $env:APPDATA 'uv'
  $destPath = Join-Path $destDirPath 'uv.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-UvConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Sync-UvConfig: NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 which exports this variable.'
  }

  $sourcePath = Join-Path $repoRoot $configRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Sync-UvConfig: source config not found at $sourcePath"
  }

  if (-not (Test-Path -Path $destDirPath -PathType Container)) {
    New-Item -Path $destDirPath -ItemType Directory -Force > $null
  }

  # Method 1 (writable symlink): remove existing file/symlink and replace with symlink.
  if (Test-Path -Path $destPath) {
    Remove-Item -Path $destPath -Force
  }
  New-Item -Path $destPath -ItemType SymbolicLink -Target $sourcePath -Force > $null
  Write-Output "$($PSStyle.Foreground.Cyan)Sync-UvConfig: symlinked $destPath$($PSStyle.Reset)"
}
