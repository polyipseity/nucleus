function Sync-DirenvConfig {
  <#
  .SYNOPSIS
    Deploys a repository-managed direnvrc writable symlink.

  .DESCRIPTION
    Creates a symbolic link from %USERPROFILE%\.config\direnv\direnvrc to
    src\modules\configs\direnv\direnvrc in the repository (Method 1).
    Edits in the repo take effect immediately without re-running apply.
    Mirrors the POSIX shell.nix deployment (base config only; the macOS-specific
    apple-sdk _nix() override in lib/ is not deployed on Windows).

  .PARAMETER Enabled
    True applies the managed config. False removes the managed symlink.

  .EXAMPLE
    Sync-DirenvConfig -Enabled:$true

  .EXAMPLE
    Sync-DirenvConfig -Enabled:$false

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must be set by caller.
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled
  )

  $configRelPath = 'src\modules\configs\direnv\direnvrc'
  $destPath = Join-Path $env:USERPROFILE '.config\direnv\direnvrc'

  if (-not $Enabled) {
    if (Test-Path -Path $destPath -PathType Leaf) {
      Remove-Item -Path $destPath -Force
      Write-Output "$($PSStyle.Foreground.Cyan)Sync-DirenvConfig: removed $destPath$($PSStyle.Reset)"
    }
    return
  }

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Sync-DirenvConfig: NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 which exports this variable.'
  }

  $sourcePath = Join-Path $repoRoot $configRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Sync-DirenvConfig: source config not found at $sourcePath"
  }

  $destDir = Split-Path -Path $destPath -Parent
  if (-not (Test-Path -Path $destDir -PathType Container)) {
    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
  }

  Deploy-WritableSymlink -SourcePath $sourcePath -DestinationPath $destPath
  Write-Output "$($PSStyle.Foreground.Cyan)Sync-DirenvConfig: deployed symlink $destPath -> $sourcePath$($PSStyle.Reset)"
}
