<#
.SYNOPSIS
  Provision hermes-agent directory, environment, and SCM service on Windows.

.DESCRIPTION
  Ensures %USERPROFILE%\data\hermes-agent\ exists, symlinks %USERPROFILE%\.hermes\
  to it, sets HERMES_HOME as a User environment variable, unprovisions any
  outdated HermesGateway Scheduled Task, installs the SCM Windows Service,
  and ensures PLAYWRIGHT_BROWSERS_PATH is set for browser tools.

  This is the Windows equivalent of the POSIX activation entries in hermes-agent.nix.

.PARAMETER Enabled
  Whether hermes-agent config provisioning should be managed.

.EXAMPLE
  Sync-HermesConfig -Enabled:$true

.NOTES
  Exit codes: 0 on success; non-zero on failure
#>

function Sync-HermesConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
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
    # Remove existing real directory if present (unprovisioning old layout)
    if (Test-Path -Path $HOME\.hermes -PathType Container) {
      Remove-Item -Path $HOME\.hermes -Recurse -Force
      Write-NucleusNotice "[$label] removed real ~/.hermes directory (creating symlink)"
    }
    $hermesDir = Split-Path -Path $hermesSymlinkTarget -Parent
    if (-not (Test-Path -Path $hermesDir)) {
      New-Item -ItemType Directory -Path $hermesDir -Force | Out-Null
    }
    New-Item -ItemType SymbolicLink -Path $hermesSymlinkTarget -Target $hermesDataDir | Out-Null
    Write-NucleusNotice "[$label] created symlink: $hermesSymlinkTarget -> $hermesDataDir"
  }

  # Set HERMES_HOME environment variable (upstream default)
  # WHY: nucleus installs via uv tool install which doesn't set HERMES_HOME.
  # The upstream installer sets it to %LOCALAPPDATA%\hermes, but nucleus
  # doesn't use the upstream installer. Set it to the upstream default so
  # hermes writes to the expected location (which is the symlink target).
  $defaultHermesHome = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'hermes'
  $currentHermesHome = [System.Environment]::GetEnvironmentVariable('HERMES_HOME', 'User')
  if ($null -eq $currentHermesHome -or $currentHermesHome -ne $defaultHermesHome) {
    [System.Environment]::SetEnvironmentVariable('HERMES_HOME', $defaultHermesHome, 'User')
    Write-NucleusNotice "[$label] set HERMES_HOME to $defaultHermesHome"
  }

  # Unprovision outdated HermesGateway Scheduled Task (if present)
  # WHY: if the user previously ran `hermes gateway install` (creating a
  # Scheduled Task), remove it before installing the SCM service to avoid
  # conflicts. This is cleanup, not migration.
  $existingTask = Get-ScheduledTask -TaskName 'HermesGateway' -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Write-NucleusNotice "[$label] removing outdated HermesGateway Scheduled Task..."
    Unregister-ScheduledTask -TaskName 'HermesGateway' -Confirm:$false
  }

  # Unprovision outdated Startup-folder droppers
  $startupDir = Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs\Startup'
  $startupHermes = Get-ChildItem -Path $startupDir -Filter '*hermes*' -ErrorAction SilentlyContinue
  foreach ($f in $startupHermes) {
    Remove-Item -Path $f.FullName -Force
    Write-NucleusNotice "[$label] removed outdated startup item: $($f.Name)"
  }

  # Install SCM Windows Service
  # WHY: SCM provides quadratic-backoff auto-restart on crash (PR #50200),
  # matching macOS launchd KeepAlive and Linux systemd Restart=always.
  # Requires admin rights (nucleus-apply runs elevated).
  $hermesBin = Get-Command -Name 'hermes' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
  if ($null -ne $hermesBin) {
    $existingSvc = Get-Service -Name 'hermes-gateway' -ErrorAction SilentlyContinue
    if ($null -eq $existingSvc) {
      Write-NucleusNotice "[$label] installing hermes-agent SCM Windows Service..."
      & $hermesBin gateway install --service-type service
      Write-NucleusNotice "[$label] hermes-agent SCM service installed"
    }
  } else {
    Write-NucleusWarning "[$label] hermes binary not found — cannot install SCM service"
  }

  # Verify SCM service exists
  $svc = Get-Service -Name 'hermes-gateway' -ErrorAction SilentlyContinue
  if ($null -eq $svc) {
    Write-NucleusWarning "[$label] hermes-gateway SCM service not found after install"
  }

  # Playwright browsers path management
  # On Windows, we check if browsers are installed in the standard location
  # and set PLAYWRIGHT_BROWSERS_PATH if needed.
  $playwrightCacheDir = Join-Path -Path $HOME -ChildPath '.cache\ms-playwright'
  $chromiumInstalled = Get-ChildItem -Path (Join-Path -Path $playwrightCacheDir -ChildPath 'chromium-*') -Directory -ErrorAction SilentlyContinue

  if ($null -eq $chromiumInstalled) {
    # Chromium not installed - attempt to install via npx
    $npxBin = $null
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
