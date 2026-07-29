function Sync-BunConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed bunfig.toml writable symlink.

  .DESCRIPTION
    Creates a symbolic link from %USERPROFILE%\.bunfig.toml to
    src\modules\configs\bun\bunfig.toml in the repository (Method 1).
    Edits in the repo take effect immediately without re-running apply.
    Mirrors the POSIX shell.nix deployment.

  .PARAMETER Enabled
    True applies the managed config. False removes the managed symlink.

  .EXAMPLE
    Sync-BunConfig -Enabled:$true

  .EXAMPLE
    Sync-BunConfig -Enabled:$false

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must be set by caller.
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled
  )

  $configRelPath = 'src\modules\configs\bun\bunfig.toml'
  $destPath = Join-Path $env:USERPROFILE '.bunfig.toml'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-BunConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Sync-BunConfig: NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 which exports this variable.'
  }

  $sourcePath = Join-Path $repoRoot $configRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Sync-BunConfig: source config not found at $sourcePath"
  }

  $destDir = Split-Path $destPath -Parent
  if ($destDir -and -not (Test-Path -Path $destDir -PathType Container)) {
    New-Item -Path $destDir -ItemType Directory -Force > $null
  }

  # Method 1 (writable symlink): remove existing file/symlink and replace with symlink.
  if (Test-Path -Path $destPath) {
    Remove-Item -Path $destPath -Force
  }
  New-Item -Path $destPath -ItemType SymbolicLink -Target $sourcePath -Force > $null
  Write-Output "$($PSStyle.Foreground.Cyan)Sync-BunConfig: symlinked $destPath$($PSStyle.Reset)"
}
