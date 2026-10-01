<#
.SYNOPSIS
  Provision hermes-agent directory, environment, and SCM service on Windows.

.DESCRIPTION
  Windows equivalent of the POSIX activation entries in hermes-agent.nix.
#>
# WHY: symlink creation needs SeCreateSymbolicLinkPrivilege (elevated session or
# Developer Mode). Probing once gives an actionable message instead of a raw
# .NET privilege exception from New-Item, and file scope lets hosts and tests stub it.
function Test-HermesSymlinkPrivilege {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) { return $true }
  $devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
  # check-suppress:suppression_doc: probe whether Developer Mode is enabled; Get-ItemProperty throws when the value is absent.
  $devModeProp = Get-ItemProperty -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
  return $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
}

. (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

# WHY a function boundary: the module writes User-scope environment variables,
# and a static [System.Environment] call cannot be stubbed.
function Get-HermesUserEnvVar {
  <#
  .SYNOPSIS
    Reads a User-scope environment variable.
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
    The first Get-Command match wins, mirroring shell PATH resolution, and the
    function boundary keeps the absence case stub-able for tests.
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

function Get-HermesBunPath {
  <#
  .SYNOPSIS
    Resolves the bun executable, or returns $null when it is not installed.

  .DESCRIPTION
    bun itself comes from the WinGet DSC package, so PATH is the whole search;
    the first match wins and the boundary keeps absence stub-able for tests.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  # check-suppress:suppression_doc: bun may not be installed; absence is the expected case and is reported by the caller
  $bun = Get-Command -Name 'bun' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $bun) {
    return $null
  }
  return $bun.Source
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
  # WHY: the CLI reads its root from HERMES_HOME (context override → env var →
  # platform default), so nucleus pins it to %LOCALAPPDATA%\hermes and the
  # plugin link lands in that root.
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

  if (-not (Test-Path -Path $hermesDataDir)) {
    New-Item -ItemType Directory -Path $hermesDataDir -Force > $null
    Write-NucleusNotice "[$label] created directory: data/hermes-agent"
  }

  # WHY no -PathType: pwsh 7 dropped that enumerator, so LinkType decides, and a
  # link whose target is gone is replaced rather than left in place.
  # check-suppress:suppression_doc: probing an optional path; absence is the expected signal and the null check below handles it.
  $hermesTargetItem = Get-Item -LiteralPath $hermesSymlinkTarget -Force -ErrorAction SilentlyContinue
  if ($null -ne $hermesTargetItem -and $hermesTargetItem.LinkType -eq 'SymbolicLink') {
    if (-not (Test-Path -LiteralPath $hermesSymlinkTarget)) {
      Remove-Item -LiteralPath $hermesSymlinkTarget -Force
      Write-NucleusNotice "[$label] removed the broken ~/.hermes symlink"
      $hermesTargetItem = $null
    }
  } elseif ($null -ne $hermesTargetItem -and $hermesTargetItem.PSIsContainer) {
    # WHY: a real directory was used here before the symlink layout.
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

  # WHY: uv tool install does not set HERMES_HOME and the upstream installer is
  # not used, so nucleus writes the same value plus the process copy, since
  # hermes writes runtime state under that root too.
  $currentHermesHome = Get-HermesUserEnvVar -Name 'HERMES_HOME'
  if ($null -eq $currentHermesHome -or $currentHermesHome -ne $defaultHermesHome) {
    Write-HermesUserEnvVar -Name 'HERMES_HOME' -Value $defaultHermesHome
    Write-NucleusNotice "[$label] set HERMES_HOME to $defaultHermesHome"
  }
  $env:HERMES_HOME = $defaultHermesHome

  # WHY: a Scheduled Task from an earlier `hermes gateway install` conflicts with
  # the SCM service installed below. Cleanup, not migration.
  # check-suppress:suppression_doc: task may not exist; probe is best-effort
  $existingTask = Get-HermesGatewayTask
  if ($null -ne $existingTask) {
    Write-NucleusNotice "[$label] removing outdated HermesGateway Scheduled Task..."
    Unregister-ScheduledTask -TaskName 'HermesGateway' -Confirm:$false
  }

  $startupDir = Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs\Startup'
  # check-suppress:suppression_doc: no matching items is expected; probe is best-effort
  $startupHermes = Get-ChildItem -Path $startupDir -Filter '*hermes*' -ErrorAction SilentlyContinue
  foreach ($f in $startupHermes) {
    Remove-Item -Path $f.FullName -Force
    Write-NucleusNotice "[$label] removed outdated startup item: $($f.Name)"
  }

  # WHY: SCM gives quadratic-backoff auto-restart on crash (PR #50200), matching
  # launchd KeepAlive and systemd Restart=always. Needs admin rights.
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

  # check-suppress:suppression_doc: service may not exist; probe is best-effort
  $svc = Get-HermesGatewayService
  if ($null -eq $svc) {
    Write-NucleusWarning "[$label] hermes-gateway SCM service not found after install"
  }

  $playwrightCacheDir = Join-Path -Path $HOME -ChildPath '.cache\ms-playwright'
  # WHY @() around the probe: a cmdlet matching nothing yields $null, so the
  #   .Count comparison below would invert silently.
  $chromiumInstalled = @(Get-ChildItem -Path (Join-Path -Path $playwrightCacheDir -ChildPath 'chromium-*') -Directory -ErrorAction SilentlyContinue) # check-suppress:suppression_doc: the cache directory is absent on a fresh host, and an absent path is the answer this probe asks for

  if ($chromiumInstalled.Count -eq 0) {
    # WHY the lockfile pin: `bun x` resolves latest by default, so an unpinned
    #   call downloads whatever the registry serves at apply time, and a missing
    #   entry is an error rather than an unversioned install.
    $lockfilePath = Join-Path -Path $RepoRoot -ChildPath 'src\lockfiles\lockfile.json'
    if (-not (Test-Path -LiteralPath $lockfilePath)) {
      Write-NucleusError -CommandName $label "lockfile not found at $lockfilePath"
    }
    $lockfile = Get-Content -LiteralPath $lockfilePath -Raw | ConvertFrom-Json
    if ($null -eq $lockfile.bun -or $null -eq $lockfile.bun.playwright) {
      Write-NucleusError -CommandName $label 'lockfile must declare bun.playwright'
    }
    $playwrightVersion = $lockfile.bun.playwright

    $bunBin = Get-HermesBunPath
    if ($null -eq $bunBin) {
      Write-NucleusWarning "[$label] bun not found - cannot install Playwright Chromium"
    } else {
      Write-NucleusNotice "[$label] installing Playwright Chromium $playwrightVersion..."
      # WHY no --with-deps: Playwright rejects the flag on Windows.
      & $bunBin x "playwright@$playwrightVersion" install chromium
      Write-NucleusNotice "[$label] Playwright Chromium installed"
    }
  } else {
    Write-NucleusNotice "[$label] Playwright Chromium already installed - skipping"
  }

  # WHY repeat the probe: naming a cache that holds nothing hides the browsers
  # hermes keeps in its own default location, and the install can fail quietly.
  $chromiumPresent = @(Get-ChildItem -Path (Join-Path -Path $playwrightCacheDir -ChildPath 'chromium-*') -Directory -ErrorAction SilentlyContinue).Count -gt 0 # check-suppress:suppression_doc: repeats the probe above, so it takes the same absent-path answer rather than raising
  if (-not $chromiumPresent) {
    Write-NucleusWarning "[$label] no Playwright Chromium found - leaving PLAYWRIGHT_BROWSERS_PATH unchanged"
  } else {
    $currentValue = Get-HermesUserEnvVar -Name 'PLAYWRIGHT_BROWSERS_PATH'
    if ($currentValue -ne $playwrightCacheDir) {
      Write-HermesUserEnvVar -Name 'PLAYWRIGHT_BROWSERS_PATH' -Value $playwrightCacheDir
      Write-NucleusNotice "[$label] set PLAYWRIGHT_BROWSERS_PATH to $playwrightCacheDir"
    }
  }

  # WHY imperative: POSIX converges the plugin list through
  # services.hermes-agent.settings, but on Windows the list lives in
  # ~/.hermes/config.yaml, which upstream rewrites at runtime.
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
    # WHY this is a real failure: the pinned CLI looks for user plugins under
    # $HERMES_HOME/plugins, which is where the link above points.
    # check-suppress:suppression_doc: Write-Error must not terminate before throw propagates the same failure
    Write-NucleusError -CommandName $label "[$label] hermes does not see the harness-bridge plugin at $pluginLink" -ErrorAction SilentlyContinue
    throw "[$label] hermes does not see the harness-bridge plugin at $pluginLink"
  }

  if ($pluginShow -match 'Status:\s*enabled') {
    Write-NucleusNotice "[$label] harness-bridge plugin already enabled"
    return
  }

  # WHY --no-allow-tool-override: the plugin registers a slash command and never
  # replaces a built-in tool.
  & $hermesCliPath plugins enable harness-bridge --no-allow-tool-override
  if ($LASTEXITCODE -ne 0) {
    # check-suppress:suppression_doc: Write-Error must not terminate before throw propagates the same failure
    Write-NucleusError -CommandName $label "[$label] 'hermes plugins enable harness-bridge' failed (exit $LASTEXITCODE)" -ErrorAction SilentlyContinue
    throw "[$label] 'hermes plugins enable harness-bridge' failed (exit $LASTEXITCODE)"
  }

  $pluginShow = & $hermesCliPath plugins show harness-bridge
  # WHY the positive form: on an array, -notmatch returns the lines that do not
  # match, so it is true for almost any output.
  if ($LASTEXITCODE -ne 0 -or -not ($pluginShow -match 'Status:\s*enabled')) {
    # check-suppress:suppression_doc: Write-Error must not terminate before throw propagates the same failure
    Write-NucleusError -CommandName $label "[$label] harness-bridge plugin is still not enabled after 'plugins enable'" -ErrorAction SilentlyContinue
    throw "[$label] harness-bridge plugin is still not enabled after 'plugins enable'"
  }
  Write-NucleusNotice "[$label] enabled the harness-bridge plugin"
}
