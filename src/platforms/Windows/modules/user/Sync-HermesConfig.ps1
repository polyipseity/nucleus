<#
.SYNOPSIS
  Provision hermes-agent directory, environment, and SCM service on Windows.

.DESCRIPTION
  Ensures %USERPROFILE%\data\hermes-agent\ exists, symlinks %USERPROFILE%\.hermes\
  to it, sets HERMES_HOME as a User environment variable, deploys the
  harness-bridge plugin under HERMES_HOME, enables it, unprovisions any
  outdated HermesGateway Scheduled Task, installs the SCM Windows Service,
  and ensures PLAYWRIGHT_BROWSERS_PATH is set for browser tools.

  This is the Windows equivalent of the POSIX activation entries in hermes-agent.nix.

.PARAMETER Enabled
  Whether hermes-agent config provisioning should be managed.

.PARAMETER RepoRoot
  Absolute path to the repository root, used to resolve the per-user overlay
  that owns the harness-bridge plugin tree.

.PARAMETER User
  Username from the user registry, used to resolve the per-user overlay.

.EXAMPLE
  Sync-HermesConfig -Enabled:$true -RepoRoot 'C:\Users\guest\repos\nucleus' -User 'guest'

.EXAMPLE
  # Cleanup path: remove the managed harness-bridge link only.
  Sync-HermesConfig -Enabled:$false -RepoRoot 'C:\Users\guest\repos\nucleus' -User 'guest'

.NOTES
  Exit codes: 0 on success; non-zero on failure
#>
# WHY: symlink creation needs SeCreateSymbolicLinkPrivilege (elevated session or
# Developer Mode).  Probing once produces an actionable message instead of a raw
# .NET privilege exception from New-Item.  Defined at file scope (like
# Sync-PiAgentConfig's Test-PiSymlinkPrivilege) so hosts and tests can stub it.
function Test-HermesSymlinkPrivilege {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) { return $true }
  $devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
  # check-suppress:suppression_doc: probe whether Developer Mode is enabled; Get-ItemProperty throws when the value is absent.
  $devModeProp = Get-ItemProperty -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
  return $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
}

. (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

# WHY these two wrappers exist: the module writes User-scope environment
# variables, and a static [System.Environment] call cannot be stubbed.  A
# function boundary keeps the behaviour testable without touching the real user
# environment store.
function Get-HermesUserEnvVar {
  <#
  .SYNOPSIS
    Reads a User-scope environment variable.
  .PARAMETER Name
    Variable name.
  .OUTPUTS
    The stored value, or $null when it is not set.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  return [System.Environment]::GetEnvironmentVariable($Name, 'User')
}

function Write-HermesUserEnvVar {
  <#
  .SYNOPSIS
    Writes a User-scope environment variable.
  .PARAMETER Name
    Variable name.
  .PARAMETER Value
    Value to store.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$Value
  )

  [System.Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}

function Get-HermesGatewayService {
  <#
  .SYNOPSIS
    Returns the hermes-gateway SCM service, or $null when it is not installed.
  .OUTPUTS
    The service object, or $null.
  #>
  [CmdletBinding()]
  [OutputType([object])]
  param()

  # check-suppress:suppression_doc: service may not exist; probe is best-effort
  return Get-Service -Name 'hermes-gateway' -ErrorAction SilentlyContinue
}

function Get-HermesGatewayTask {
  <#
  .SYNOPSIS
    Returns the outdated HermesGateway scheduled task, or $null when absent.
  .OUTPUTS
    The task object, or $null.
  #>
  [CmdletBinding()]
  [OutputType([object])]
  param()

  # check-suppress:suppression_doc: task may not exist; probe is best-effort
  return Get-ScheduledTask -TaskName 'HermesGateway' -ErrorAction SilentlyContinue
}

function Get-HermesCliPath {
  <#
  .SYNOPSIS
    Resolves the hermes executable, or returns $null when it is not installed.

  .DESCRIPTION
    `Get-Command hermes` can return several executables when more than one copy
    is on PATH, so the first match wins, mirroring shell PATH resolution.  A
    function boundary keeps the absence case stub-able for tests.
  .OUTPUTS
    Absolute path to the hermes executable, or $null.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  # check-suppress:suppression_doc: hermes may not be installed; absence is the expected case and is reported by the caller
  $hermesCli = Get-Command -Name 'hermes' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $hermesCli) {
    return $null
  }
  return $hermesCli.Source
}

function Sync-HermesConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$User
  )

  $label = 'hermes-config'
  # WHY: HERMES_HOME is where the CLI keeps its config and user plugins
  # (hermes_constants.get_hermes_home: context override → HERMES_HOME → the
  # platform-native default, which on Windows is %LOCALAPPDATA%\hermes).  nucleus
  # owns that value, so the plugin link is placed in the root the CLI reads, and
  # the process copy is set below so this run's CLI calls agree with it.
  $defaultHermesHome = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'hermes'
  $hermesPluginRelPath = 'plugins\harness-bridge'
  $pluginLink = Join-Path -Path (Join-Path -Path $defaultHermesHome -ChildPath 'plugins') -ChildPath 'harness-bridge'

  if (-not $Enabled) {
    if (Test-Path -LiteralPath $pluginLink) {
      Remove-ManagedSymlinkDeleteProtection -Context $label -Path $pluginLink
      Remove-Item -LiteralPath $pluginLink -Force
      Write-NucleusNotice "[$label] removed $pluginLink"
    }
    Write-NucleusNotice "[$label] disabled — skipping"
    return
  }

  $dataDir = Join-Path -Path $HOME -ChildPath 'data'
  $hermesDataDir = Join-Path -Path $dataDir -ChildPath 'hermes-agent'
  $hermesSymlinkTarget = Join-Path -Path $HOME -ChildPath '.hermes'

  # Ensure ~/data/hermes-agent/ exists
  if (-not (Test-Path -Path $hermesDataDir)) {
    New-Item -ItemType Directory -Path $hermesDataDir -Force > $null
    Write-NucleusNotice "[$label] created directory: data/hermes-agent"
  }

  # Create directory symlink ~/.hermes/ -> ~/data/hermes-agent/
  # WHY no -PathType SymbolicLink: PowerShell 7 dropped that enumerator, and
  # nucleus runs pwsh 7 on Windows, so the link is recognised through LinkType
  # instead.  A link whose target is gone is replaced rather than left in place,
  # which is what the previous form could not express.
  $hermesTargetItem = Get-Item -LiteralPath $hermesSymlinkTarget -Force -ErrorAction SilentlyContinue
  if ($null -ne $hermesTargetItem -and $hermesTargetItem.LinkType -eq 'SymbolicLink') {
    if (-not (Test-Path -LiteralPath $hermesSymlinkTarget)) {
      Remove-Item -LiteralPath $hermesSymlinkTarget -Force
      Write-NucleusNotice "[$label] removed the broken ~/.hermes symlink"
      $hermesTargetItem = $null
    }
  } elseif ($null -ne $hermesTargetItem -and $hermesTargetItem.PSIsContainer) {
    # Unprovisioning the old layout: a real directory was used before the symlink.
    Remove-Item -Path $HOME\.hermes -Recurse -Force
    Write-NucleusNotice "[$label] removed real ~/.hermes directory (creating symlink)"
    $hermesTargetItem = $null
  } elseif ($null -ne $hermesTargetItem) {
    Remove-Item -LiteralPath $hermesSymlinkTarget -Force
    Write-NucleusNotice "[$label] removed the stale ~/.hermes entry (creating symlink)"
    $hermesTargetItem = $null
  }
  if ($null -eq $hermesTargetItem) {
    New-Item -ItemType Directory -Path (Split-Path -Path $hermesSymlinkTarget -Parent) -Force > $null
    New-Item -ItemType SymbolicLink -Path $hermesSymlinkTarget -Target $hermesDataDir > $null
    Write-NucleusNotice "[$label] created symlink: $hermesSymlinkTarget -> $hermesDataDir"
  }

  # Set HERMES_HOME environment variable (upstream default)
  # WHY: nucleus installs via uv tool install which doesn't set HERMES_HOME.
  # The upstream installer sets it to %LOCALAPPDATA%\hermes, but nucleus
  # doesn't use the upstream installer, so nucleus writes the same value and
  # sets the process copy too: hermes also writes runtime state under
  # HERMES_HOME, and the plugin link above has to be in that same root.
  $currentHermesHome = Get-HermesUserEnvVar -Name 'HERMES_HOME'
  if ($null -eq $currentHermesHome -or $currentHermesHome -ne $defaultHermesHome) {
    Write-HermesUserEnvVar -Name 'HERMES_HOME' -Value $defaultHermesHome
    Write-NucleusNotice "[$label] set HERMES_HOME to $defaultHermesHome"
  }
  $env:HERMES_HOME = $defaultHermesHome

  # Unprovision outdated HermesGateway Scheduled Task (if present)
  # WHY: if the user previously ran `hermes gateway install` (creating a
  # Scheduled Task), remove it before installing the SCM service to avoid
  # conflicts. This is cleanup, not migration.
  # check-suppress:suppression_doc: task may not exist; probe is best-effort
  $existingTask = Get-HermesGatewayTask
  if ($null -ne $existingTask) {
    Write-NucleusNotice "[$label] removing outdated HermesGateway Scheduled Task..."
    Unregister-ScheduledTask -TaskName 'HermesGateway' -Confirm:$false
  }

  # Unprovision outdated Startup-folder droppers
  $startupDir = Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs\Startup'
  # check-suppress:suppression_doc: no matching items is expected; probe is best-effort
  $startupHermes = Get-ChildItem -Path $startupDir -Filter '*hermes*' -ErrorAction SilentlyContinue
  foreach ($f in $startupHermes) {
    Remove-Item -Path $f.FullName -Force
    Write-NucleusNotice "[$label] removed outdated startup item: $($f.Name)"
  }

  # Install SCM Windows Service
  # WHY: SCM provides quadratic-backoff auto-restart on crash (PR #50200),
  # matching macOS launchd KeepAlive and Linux systemd Restart=always.
  # Requires admin rights (nucleus-apply runs elevated).
  # check-suppress:suppression_doc: hermes may not be installed; probe is best-effort
  $hermesBin = Get-HermesCliPath
  if ($null -ne $hermesBin) {
    # check-suppress:suppression_doc: service may not exist; probe is best-effort
    $existingSvc = Get-HermesGatewayService
    if ($null -eq $existingSvc) {
      Write-NucleusNotice "[$label] installing hermes-agent SCM Windows Service..."
      & $hermesBin gateway install --service-type service
      Write-NucleusNotice "[$label] hermes-agent SCM service installed"
    }
  } else {
    Write-NucleusWarning "[$label] hermes binary not found — cannot install SCM service"
  }

  # Verify SCM service exists
  # check-suppress:suppression_doc: service may not exist; probe is best-effort
  $svc = Get-HermesGatewayService
  if ($null -eq $svc) {
    Write-NucleusWarning "[$label] hermes-gateway SCM service not found after install"
  }

  # Playwright browsers path management
  # On Windows, we check if browsers are installed in the standard location
  # and set PLAYWRIGHT_BROWSERS_PATH if needed.
  $playwrightCacheDir = Join-Path -Path $HOME -ChildPath '.cache\ms-playwright'
  # check-suppress:suppression_doc: directory may not exist; probe is best-effort
  $chromiumInstalled = Get-ChildItem -Path (Join-Path -Path $playwrightCacheDir -ChildPath 'chromium-*') -Directory -ErrorAction SilentlyContinue

  if ($null -eq $chromiumInstalled) {
    # Chromium not installed - attempt to install via npx
    $npxBin = $null
    if ($null -ne $hermesBin) {
      $hermesStorePath = Split-Path -Path (Split-Path -Path $hermesBin -Parent) -Parent
      $npxCandidate = Join-Path -Path $hermesStorePath -ChildPath 'bin\npx'
      if (Test-Path -Path $npxCandidate) {
        $npxBin = $npxCandidate
      }
    }
    if ($null -eq $npxBin) {
      # check-suppress:suppression_doc: npx may not be installed; probe is best-effort
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
  $currentValue = Get-HermesUserEnvVar -Name 'PLAYWRIGHT_BROWSERS_PATH'
  if ($currentValue -ne $playwrightCacheDir) {
    Write-HermesUserEnvVar -Name 'PLAYWRIGHT_BROWSERS_PATH' -Value $playwrightCacheDir
    Write-NucleusNotice "[$label] set PLAYWRIGHT_BROWSERS_PATH to $playwrightCacheDir"
  }

  # Expose the harness bridge inside chat: the plugin adds /harness, which is
  # the inbound half of the bridge (approve/deny and `/harness send`).
  # WHY imperative: POSIX converges the plugin list through
  # services.hermes-agent.settings, but on Windows it lives in ~/.hermes/config.yaml,
  # which upstream rewrites at runtime, so the CLI is the convergent interface.
  $pluginSource = Resolve-UserConfigFile -User $User -ConfigName 'hermes' -RelativePath $hermesPluginRelPath -RepoRoot $RepoRoot
  $pluginDir = Split-Path -Path $pluginLink -Parent
  if (-not (Test-Path -Path $pluginDir -PathType Container)) {
    New-Item -Path $pluginDir -ItemType Directory -Force > $null
  }
  if (-not (Test-HermesSymlinkPrivilege)) {
    Write-NucleusWarning "[$label] cannot create the harness-bridge symlink without elevation or Developer Mode"
    return
  }
  if (Test-Path -LiteralPath $pluginLink) {
    $pluginItem = Get-Item -LiteralPath $pluginLink -Force
    $isPluginSymlink = ($pluginItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
      -and $pluginItem.LinkType -eq 'SymbolicLink'
    if (-not $isPluginSymlink) {
      Write-NucleusError -CommandName $label "$pluginLink is not a managed symlink — a hand-installed plugin must be removed before apply can manage the bridge"
      throw "[$label] refusing to replace the real directory $pluginLink"
    }
    if ([string]::Equals($pluginItem.Target, $pluginSource, [System.StringComparison]::OrdinalIgnoreCase)) {
      Write-NucleusNotice "[$label] harness-bridge plugin already linked"
    } else {
      Remove-ManagedSymlinkDeleteProtection -Context $label -Path $pluginLink
      Remove-Item -LiteralPath $pluginLink -Force
    }
  }
  if (-not (Test-Path -LiteralPath $pluginLink)) {
    New-Item -ItemType SymbolicLink -Path $pluginLink -Target $pluginSource > $null
    Set-ManagedSymlinkDeleteProtection -Context $label -Path $pluginLink
    Write-NucleusNotice "[$label] linked $pluginLink -> $pluginSource"
  }

  # check-suppress:suppression_doc: hermes may not be installed; absence is the expected case and is reported as a warning right below
  $hermesCliPath = Get-HermesCliPath
  if ($null -eq $hermesCliPath) {
    Write-NucleusWarning "[$label] hermes binary not found — cannot enable the harness-bridge plugin"
    return
  }

  $pluginShow = & $hermesCliPath plugins show harness-bridge
  if ($LASTEXITCODE -ne 0) {
    # The link above is where the pinned CLI looks for user plugins
    # ($HERMES_HOME/plugins), so an undiscovered plugin here is a real failure
    # rather than a Windows-specific gap.
    # check-suppress:suppression_doc: Write-Error must not terminate before throw propagates the same failure
    Write-NucleusError -CommandName $label "[$label] hermes does not see the harness-bridge plugin at $pluginLink" -ErrorAction SilentlyContinue
    throw "[$label] hermes does not see the harness-bridge plugin at $pluginLink"
  }

  if ($pluginShow -match 'Status:\s*enabled') {
    Write-NucleusNotice "[$label] harness-bridge plugin already enabled"
    return
  }

  # --no-allow-tool-override keeps the call non-interactive: the plugin registers a
  # slash command and never replaces a built-in tool.
  & $hermesCliPath plugins enable harness-bridge --no-allow-tool-override
  if ($LASTEXITCODE -ne 0) {
    # check-suppress:suppression_doc: Write-Error must not terminate before throw propagates the same failure
    Write-NucleusError -CommandName $label "[$label] 'hermes plugins enable harness-bridge' failed (exit $LASTEXITCODE)" -ErrorAction SilentlyContinue
    throw "[$label] 'hermes plugins enable harness-bridge' failed (exit $LASTEXITCODE)"
  }

  $pluginShow = & $hermesCliPath plugins show harness-bridge
  # WHY the positive form: on an array, -notmatch returns the lines that do NOT
  # match, so it is true for almost any output.
  if ($LASTEXITCODE -ne 0 -or -not ($pluginShow -match 'Status:\s*enabled')) {
    # check-suppress:suppression_doc: Write-Error must not terminate before throw propagates the same failure
    Write-NucleusError -CommandName $label "[$label] harness-bridge plugin is still not enabled after 'plugins enable'" -ErrorAction SilentlyContinue
    throw "[$label] harness-bridge plugin is still not enabled after 'plugins enable'"
  }
  Write-NucleusNotice "[$label] enabled the harness-bridge plugin"
}
