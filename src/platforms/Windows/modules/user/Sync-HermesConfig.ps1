<#
.SYNOPSIS
  Provision hermes-agent SOUL.md and set Playwright browsers path on Windows.

.DESCRIPTION
  Ensures %USERPROFILE%\data\hermes-agent\ exists, symlinks %USERPROFILE%\.hermes\
  to it, and ensures PLAYWRIGHT_BROWSERS_PATH is set for browser tools.

  This is the Windows equivalent of the POSIX activation entries in hermes-agent.nix.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout.

.PARAMETER Enabled
  Whether hermes-agent config provisioning should be managed.

.PARAMETER Username
  Username for path resolution.

.EXAMPLE
  Sync-HermesConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$true -Username 'polyipseity'

.NOTES
  Exit codes: 0 on success; non-zero on failure
#>

function Sync-HermesConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled,
    [Parameter(Mandatory)]
    [string]$Username
  )

  $label = 'hermes-config'
  if (-not $Enabled) {
    Write-NucleusNotice "[$label] disabled — skipping"
    return
  }

  $dataDir = Join-Path -Path $HOME -ChildPath 'data'
  $hermesDataDir = Join-Path -Path $dataDir -ChildPath 'hermes-agent'
  $hermesSymlinkTarget = Join-Path -Path $HOME -ChildPath '.hermes'

  # Ensure ~/data/hermes-agent/ exists
  if (-not (Test-Path -Path $hermesDataDir)) {
    New-Item -ItemType Directory -Path $hermesDataDir -Force | Out-Null
    Write-NucleusNotice "[$label] created directory: data/hermes-agent"
  }

  # Create directory symlink ~/.hermes/ -> ~/data/hermes-agent/
  # Skip if symlink already exists or target directory already present
  if (-not (Test-Path -Path $hermesSymlinkTarget) -and -not (Test-Path -Path $hermesSymlinkTarget -PathType SymbolicLink)) {
    # Remove existing real directory if present (migration from old layout)
    if (Test-Path -Path $HOME\.hermes -PathType Container) {
      Remove-Item -Path $HOME\.hermes -Recurse -Force
      Write-NucleusNotice "[$label] removed real ~/.hermes directory (migrating to symlink)"
    }
    $hermesDir = Split-Path -Path $hermesSymlinkTarget -Parent
    if (-not (Test-Path -Path $hermesDir)) {
      New-Item -ItemType Directory -Path $hermesDir -Force | Out-Null
    }
    New-Item -ItemType SymbolicLink -Path $hermesSymlinkTarget -Target $hermesDataDir | Out-Null
    Write-NucleusNotice "[$label] created symlink: $hermesSymlinkTarget -> $hermesDataDir"
  }

  # Playwright browsers path management
  # On Windows, we check if browsers are installed in the standard location
  # and set PLAYWRIGHT_BROWSERS_PATH if needed.
  $playwrightCacheDir = Join-Path -Path $HOME -ChildPath '.cache\ms-playwright'
  $chromiumInstalled = Get-ChildItem -Path (Join-Path -Path $playwrightCacheDir -ChildPath 'chromium-*') -Directory -ErrorAction SilentlyContinue

  if ($null -eq $chromiumInstalled) {
    # Chromium not installed - attempt to install via npx
    $npxBin = $null
    $hermesBin = Get-Command -Name 'hermes' -ErrorAction SilentlyContinue
    if ($null -ne $hermesBin) {
      $hermesStorePath = Split-Path -Path (Split-Path -Path $hermesBin.Source -Parent) -Parent
      $npxCandidate = Join-Path -Path $hermesStorePath -ChildPath 'bin\npx'
      if (Test-Path -Path $npxCandidate) {
        $npxBin = $npxCandidate
      }
    }
    if ($null -eq $npxBin) {
      $npxBin = Get-Command -Name 'npx' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    }

    if ($null -ne $npxBin) {
      Write-NucleusNotice "[$label] installing Playwright Chromium..."
      & $npxBin playwright install --with-deps chromium
      Write-NucleusNotice "[$label] Playwright Chromium installed"
    } else {
      Write-NucleusWarning "[$label] npx not found — cannot install Playwright Chromium"
    }
  } else {
    Write-NucleusNotice "[$label] Playwright Chromium already installed — skipping"
  }

  # Set PLAYWRIGHT_BROWSERS_PATH if not already set
  $currentValue = [System.Environment]::GetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH', 'User')
  if ($currentValue -ne $playwrightCacheDir) {
    [System.Environment]::SetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH', $playwrightCacheDir, 'User')
    Write-NucleusNotice "[$label] set PLAYWRIGHT_BROWSERS_PATH to $playwrightCacheDir"
  }
}
