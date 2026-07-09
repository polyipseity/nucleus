function Sync-StarshipConfig {
  <#
  .SYNOPSIS
    Deploys the repository-managed starship.toml config to the correct path.

  .DESCRIPTION
    Reads src/modules/configs/starship.toml from the repository (resolved via
    NUCLEUS_REPO_ROOT) and writes it to the path expected by STARSHIP_CONFIG
    (set in user/env.dsc.yml: %USERPROFILE%\.config\starship.toml).

    Only overwrites if the destination differs from the source, to avoid
    unnecessary file I/O on every apply.

  .PARAMETER Enabled
    True applies the managed config. False removes the managed config file.

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

  $sourceContent = Get-Content -Path $sourcePath -Raw -Encoding UTF8
  $destExists = Test-Path -Path $destPath -PathType Leaf
  $needsUpdate = $true

  if ($destExists) {
    $destContent = Get-Content -Path $destPath -Raw -Encoding UTF8
    $needsUpdate = ($sourceContent -ne $destContent)
  }

  if ($needsUpdate) {
    Set-Content -Path $destPath -Value $sourceContent -Encoding UTF8 -NoNewline
    Write-Host "Sync-StarshipConfig: deployed $destPath" -ForegroundColor DarkCyan
  }
}
