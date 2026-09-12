<#
.SYNOPSIS
  Provision hermes-agent SOUL.md and set Playwright browsers path on Windows.

.DESCRIPTION
  Ensures %USERPROFILE%\data\hermes-agent\ exists, creates a default SOUL.md
  if not present, symlinks %USERPROFILE%\.hermes\SOUL.md to it, and ensures
  PLAYWRIGHT_BROWSERS_PATH is set for browser tools.

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
  $soulMdSource = Join-Path -Path $hermesDataDir -ChildPath 'SOUL.md'
  $soulMdTarget = Join-Path -Path $HOME -ChildPath '.hermes\SOUL.md'

  # Default SOUL.md content (matches POSIX default in data-directory.nix)
  $defaultSoulContent = @'
You are Hermes Agent, built by Nous Research. Be direct: match the length of your reply to the weight of the ask — a one-line question gets a one-line answer, and finished work gets a short report of what changed, what's verified, and what's left, never a replay of the process. No filler ("Great question," "I'd be happy to"), no restating the request back, no re-summarizing what you already said, no narrating tool calls the user can see. Plain claims over adjectives; when unsure, say so plainly. Agree because it's right, not because the user said it. Depth is earned — give it when the user asks for detail, teaches, or the stakes demand it, not by default.
'@

  # Ensure ~/data/hermes-agent/ exists
  if (-not (Test-Path -Path $hermesDataDir)) {
    New-Item -ItemType Directory -Path $hermesDataDir -Force | Out-Null
    Write-NucleusNotice "[$label] created directory: data/hermes-agent"
  }

  # Create default SOUL.md if not exists
  if (-not (Test-Path -Path $soulMdSource)) {
    Set-Content -Path $soulMdSource -Value $defaultSoulContent -NoNewline
    Write-NucleusNotice "[$label] created file: data/hermes-agent/SOUL.md"
  }

  # Create symlink ~/.hermes/SOUL.md -> ~/data/hermes-agent/SOUL.md
  # Skip if symlink already exists or target already present
  if (-not (Test-Path -Path $soulMdTarget) -and -not (Test-Path -Path $soulMdTarget -PathType SymbolicLink)) {
    $hermesDir = Split-Path -Path $soulMdTarget -Parent
    if (-not (Test-Path -Path $hermesDir)) {
      New-Item -ItemType Directory -Path $hermesDir -Force | Out-Null
    }
    New-Item -ItemType SymbolicLink -Path $soulMdTarget -Target $soulMdSource | Out-Null
    Write-NucleusNotice "[$label] created symlink: $soulMdTarget -> $soulMdSource"
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
