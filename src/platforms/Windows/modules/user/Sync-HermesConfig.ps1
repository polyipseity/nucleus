<#
.SYNOPSIS
  Provision the hermes-agent directory and environment on Windows, with a
  per-user gateway autostart value and no SCM registration.

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

function Remove-HermesGatewayService {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  # WHY: the SCM registration predates the user-scoped Run key. Deleting it
  # converges hosts that were managed by an earlier apply.
  $existing = Get-HermesGatewayService
  if ($null -eq $existing) { return }
  if (-not $PSCmdlet.ShouldProcess('hermes-gateway', 'Remove SCM service')) { return }
  if ($existing.Status -ne 'Stopped') {
    Stop-Service -Name 'hermes-gateway' -Force
  }
  & sc.exe delete 'hermes-gateway' > $null
}

function Set-HermesGatewayRunValue {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Command
  )

  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  if (-not $PSCmdlet.ShouldProcess($runKey, "Set $Name")) { return }
  if (-not (Test-Path -LiteralPath $runKey)) {
    New-Item -Path $runKey -Force > $null
  }
  New-ItemProperty -Path $runKey -Name $Name -Value $Command -PropertyType String -Force > $null
}

function Remove-HermesGatewayRunValue {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Name)

  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  if (-not (Test-Path -LiteralPath $runKey)) { return }
  if (-not $PSCmdlet.ShouldProcess($runKey, "Remove $Name")) { return }
  # WHY: absence is the converged state, so a missing value is not an error.
  Remove-ItemProperty -Path $runKey -Name $Name -ErrorAction SilentlyContinue # check-suppress:suppression_doc: Remove-ItemProperty errors when the nucleus-hermes-gateway Run value is absent on first provision; Test-Path above still guards the Run key, and a missing value is the converged state
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

function Get-HermesEnvSecretSpec {
  <#
  .SYNOPSIS
    Selects the user-scoped Hermes entries from the env-secrets catalog.
  #>
  [CmdletBinding()]
  [OutputType([object[]])]
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$User
  )

  # The user domain replaces the default wholesale (users-registry.nix),
  # so only one catalog file is read.
  $userCatalog = Join-Path -Path $RepoRoot -ChildPath "src\users\$User\env-secrets.json"
  $defaultCatalog = Join-Path -Path $RepoRoot -ChildPath 'src\users\default\env-secrets.json'
  $catalogPath = if (Test-Path -LiteralPath $userCatalog -PathType Leaf) { $userCatalog } else { $defaultCatalog }
  if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "hermes-config: env-secrets catalog not found at $catalogPath"
  }

  $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $catalog.secrets) {
    throw "hermes-config: env-secrets catalog has no 'secrets' array: $catalogPath"
  }

  $specs = @()
  foreach ($entry in @($catalog.secrets)) {
    # POSIX renders the two .env files from hermesUserSecrets: consumer
    # hermes-agent and sopsSource user. System secrets stay with litellm.
    if (@($entry.consumers) -contains 'hermes-agent' -and $entry.sopsSource -eq 'user') {
      $specs += [PSCustomObject]@{ name = $entry.name; envVar = $entry.envVar }
    }
  }
  return $specs
}

function Get-HermesDecryptedUserSecret {
  <#
  .SYNOPSIS
    Decrypts the user SOPS file that backs the Hermes .env files.
  #>
  [CmdletBinding()]
  [OutputType([object])]
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$User
  )

  $secretFile = Join-Path -Path $RepoRoot -ChildPath "src\secrets\users\$User.yml"
  if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
    throw "hermes-config: user SOPS file not found at $secretFile"
  }

  # Same candidate order as apply.ps1: WinGet first, then PATH.
  # check-suppress:suppression_doc: probe -- the WinGet package directory is absent on some hosts; PATH is the fallback.
  $sopsPackageDir = Get-ChildItem -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WinGet\Packages\SecretsOPerationS.SOPS_*') -Directory -ErrorAction SilentlyContinue |
    Sort-Object -Property Name -Descending | Select-Object -First 1
  $sopsCandidates = @()
  if ($null -ne $sopsPackageDir) {
    $sopsCandidates += Join-Path -Path $sopsPackageDir.FullName -ChildPath 'sops.exe'
  }
  # check-suppress:suppression_doc: probe -- sops may not be on PATH; Resolve-Executable reports the missing tool.
  $sopsFromPath = Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
  if (-not [string]::IsNullOrWhiteSpace($sopsFromPath)) {
    $sopsCandidates += $sopsFromPath
  }
  $gpgCandidates = @(
    (Join-Path -Path $env:ProgramFiles -ChildPath 'GnuPG\bin\gpg.exe'),
    (Join-Path -Path "${env:ProgramFiles(x86)}" -ChildPath 'GnuPG\bin\gpg.exe'),
    # check-suppress:suppression_doc: probe -- gpg may not be on PATH; Resolve-Executable reports the missing tool.
    (Get-Command -Name 'gpg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $secretParams = @{
    FilePath    = $secretFile
    GpgExe      = Resolve-Executable -Name 'gpg' -CandidatePaths $gpgCandidates
    HostKeyPath = Join-Path -Path $env:ProgramData -ChildPath 'ssh\ssh_host_ed25519_key'
    RepoRoot    = $RepoRoot
    SopsExe     = Resolve-Executable -Name 'sops' -CandidatePaths $sopsCandidates
  }
  return Get-Secret @secretParams
}

function Deploy-HermesDirectoryLink {
  <#
  .SYNOPSIS
    Links an overlay-owned skill directory into the Hermes profile tree.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$LinkPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "[$Name] overlay source not found: $SourcePath"
  }
  $parent = Split-Path -Path $LinkPath -Parent
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force > $null
  }

  # WHY Get-Item, not Test-Path: a broken symlink has to be replaced, and
  # Test-Path would report it as absent while New-Item still sees the path.
  # check-suppress:suppression_doc: probe -- a missing link is the expected first-provision case.
  $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
  if ($null -ne $existing) {
    if ($existing.LinkType -ne 'SymbolicLink') {
      throw "[$Name] refusing to replace the real directory $LinkPath"
    }
    if ([string]::Equals($existing.Target, $SourcePath, [System.StringComparison]::OrdinalIgnoreCase)) {
      return
    }
    Remove-ManagedSymlinkDeleteProtection -Context $Name -Path $LinkPath
    Remove-Item -LiteralPath $LinkPath -Force
  }
  New-Item -ItemType SymbolicLink -Path $LinkPath -Target $SourcePath > $null
  Set-ManagedSymlinkDeleteProtection -Context $Name -Path $LinkPath
}

function Write-HermesEnvFile {
  <#
  .SYNOPSIS
    Renders one dotenv document to the CLI and gateway profile targets.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string[]]$TargetPaths,
    [Parameter(Mandatory)][object[]]$SecretSpecs,
    [Parameter(Mandatory)][object]$DecryptedSecrets
  )

  $lines = @()
  foreach ($spec in $SecretSpecs) {
    $property = $DecryptedSecrets.PSObject.Properties[$spec.name]
    if ($null -eq $property) {
      throw "hermes-config: SOPS user secrets are missing $($spec.name)"
    }
    $lines += "$($spec.envVar)=$( [string]$property.Value )"
  }
  $content = $lines -join "`n"

  foreach ($target in $TargetPaths) {
    $parent = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Path $parent -Force > $null
    }
    [System.IO.File]::WriteAllText($target, $content, [System.Text.UTF8Encoding]::new($false))
    if ($IsWindows) {
      # sops-nix writes mode 0600 on POSIX; the user key is the only grant here.
      $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      & icacls.exe $target /inheritance:r /grant:r "${identity}:(F)" > $null
      if ($LASTEXITCODE -ne 0) {
        throw "hermes-config: could not restrict ACL on $target (icacls exit $LASTEXITCODE)"
      }
    }
  }
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
  # WHY: HERMES_HOME is the authoritative resolver for the CLI's config and
  # user-data home, including profiles. Nucleus points it at the managed
  # ~/.hermes root so the config, profile, and plugin paths share one home.
  $hermesSymlinkTarget = Join-Path -Path $HOME -ChildPath '.hermes'
  $managedHermesHome = $hermesSymlinkTarget
  $hermesPluginRelPath = 'plugins\harness-bridge'
  # WHY mirrored from hermes-agent.nix: the gateway profile carries the same six
  # user-scope bundles as the CLI, so the overlay paths are resolved per host.
  $hermesSkillNames = @(
    'nucleus-citation-reference'
    'nucleus-harness-reference'
    'nucleus-platform-reference'
    'nucleus-policy-reference'
    'nucleus-service-reference'
    'nucleus-vm-reference'
  )
  $pluginLink = Join-Path -Path (Join-Path -Path $managedHermesHome -ChildPath 'plugins') -ChildPath 'harness-bridge'

  if (-not $Enabled) {
    if (Test-Path -LiteralPath $pluginLink) {
      Remove-ManagedSymlinkDeleteProtection -Context $label -Path $pluginLink
      Remove-Item -LiteralPath $pluginLink -Force
      Write-NucleusNotice "[$label] removed $pluginLink"
    }
    Remove-HermesGatewayService
    Remove-HermesGatewayRunValue -Name 'nucleus-hermes-gateway'
    Write-NucleusNotice "[$label] disabled — skipping"
    return
  }

  $dataDir = Join-Path -Path $HOME -ChildPath 'data'
  $hermesDataDir = Join-Path -Path $dataDir -ChildPath 'hermes-agent'

  if (-not (Test-Path -Path $hermesDataDir)) {
    New-Item -ItemType Directory -Path $hermesDataDir -Force > $null
    Write-NucleusNotice "[$label] created directory: data/hermes-agent"
  }

  # WHY: the guard and stale autostart cleanup precede the ~/.hermes symlink
  # attempt so a host without the privilege gets the warning, not a .NET error.
  # WHY: the Run value starts the gateway with this profile, so a run that cannot
  # create links must still clear a stale autostart carrier.
  Remove-HermesGatewayService
  Remove-HermesGatewayRunValue -Name 'nucleus-hermes-gateway'
  if (-not (Test-HermesSymlinkPrivilege)) {
    Write-NucleusWarning "[$label] cannot create the Hermes profile links without elevation or Developer Mode"
    return
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

  # WHY: the CLI resolves its config and user-data home from HERMES_HOME, so
  # the User-scope value and this process's copy both point at the managed
  # ~/.hermes root that carries the profile tree.
  $currentHermesHome = Get-HermesUserEnvVar -Name 'HERMES_HOME'
  if ($null -eq $currentHermesHome -or $currentHermesHome -ne $managedHermesHome) {
    Write-HermesUserEnvVar -Name 'HERMES_HOME' -Value $managedHermesHome
    Write-NucleusNotice "[$label] set HERMES_HOME to $managedHermesHome"
  }
  $env:HERMES_HOME = $managedHermesHome

  # WHY: a Scheduled Task from an earlier `hermes gateway install` conflicts with
  # the user Run key installed below. Cleanup, not migration.
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

  # WHY: --profile gateway is on the Run command line, so the profile and its
  # secrets have to be materialized before the value is written. A host that
  # cannot create the links must not advertise a gateway that cannot start.
  $gatewayProfileDir = Join-Path -Path (Join-Path -Path $hermesSymlinkTarget -ChildPath 'profiles') -ChildPath 'gateway'
  if (-not (Test-Path -LiteralPath $gatewayProfileDir -PathType Container)) {
    New-Item -ItemType Directory -Path $gatewayProfileDir -Force > $null
  }
  $hermesFileLinks = @(
    @{ Name = 'hermes-cli-config'; RelativePath = 'config.yaml'; TargetPath = (Join-Path -Path $hermesSymlinkTarget -ChildPath 'config.yaml') }
    @{ Name = 'hermes-cli-soul'; RelativePath = 'SOUL.md'; TargetPath = (Join-Path -Path $hermesSymlinkTarget -ChildPath 'SOUL.md') }
    @{ Name = 'hermes-gateway-config'; RelativePath = 'profiles/gateway/config.yaml'; TargetPath = (Join-Path -Path $gatewayProfileDir -ChildPath 'config.yaml') }
    @{ Name = 'hermes-gateway-soul'; RelativePath = 'SOUL.md'; TargetPath = (Join-Path -Path $gatewayProfileDir -ChildPath 'SOUL.md') }
  )
  foreach ($link in $hermesFileLinks) {
    # WHY: Deploy-WritableSymlink removes the current target before linking, and
    # the delete-protection ACL has to be cleared first on a second activation.
    # check-suppress:suppression_doc: probe -- a missing link is the expected first-provision case.
    $existingLink = Get-Item -LiteralPath $link.TargetPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingLink) {
      Remove-ManagedSymlinkDeleteProtection -Context $label -Path $link.TargetPath
    }
    $deployment = Deploy-UserWritableSymlink -Name $link.Name -User $User -ConfigName 'hermes' -RelativePath $link.RelativePath -RepoRoot $RepoRoot -TargetPath $link.TargetPath
    Set-ManagedSymlinkDeleteProtection -Context $label -Path $link.TargetPath
    Write-NucleusNotice "[$label] $($deployment.Message)"
  }

  $cliSkillsSource = Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'hermes' -EntryName 'skills' -RepoRoot $RepoRoot
  Deploy-HermesDirectoryLink -Name 'hermes-cli-skills' -SourcePath $cliSkillsSource -LinkPath (Join-Path -Path $hermesSymlinkTarget -ChildPath 'skills')
  # WHY: POSIX exposes the live checkout through $HERMES_HOME/repo for the
  # gateway; the same managed-link pattern keeps it replaceable on re-apply.
  Deploy-HermesDirectoryLink -Name 'hermes-repo' -SourcePath $RepoRoot -LinkPath (Join-Path -Path $managedHermesHome -ChildPath 'repo')
  $gatewaySkillsDir = Join-Path -Path $gatewayProfileDir -ChildPath 'skills'
  if (-not (Test-Path -LiteralPath $gatewaySkillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $gatewaySkillsDir -Force > $null
  }
  foreach ($name in $hermesSkillNames) {
    $skillSource = Resolve-UserConfigFile -User $User -ConfigName 'agents' -RelativePath "skills/$name" -RepoRoot $RepoRoot
    Deploy-HermesDirectoryLink -Name "hermes-gateway-$name" -SourcePath $skillSource -LinkPath (Join-Path -Path $gatewaySkillsDir -ChildPath $name)
  }

  $envSpecs = Get-HermesEnvSecretSpec -RepoRoot $RepoRoot -User $User
  if ($envSpecs.Count -gt 0) {
    $decryptedSecrets = Get-HermesDecryptedUserSecret -RepoRoot $RepoRoot -User $User
    Write-HermesEnvFile -TargetPaths @(
      (Join-Path -Path $hermesSymlinkTarget -ChildPath '.env'),
      (Join-Path -Path $gatewayProfileDir -ChildPath '.env')
    ) -SecretSpecs $envSpecs -DecryptedSecrets $decryptedSecrets
  }

  # WHY: the gateway owns per-user secrets and profile state, so logon-owned
  # HKCU Run is the carrier. The SCM service and stale Run value were cleared
  # before this point, so only the current autostart value remains.
  # check-suppress:suppression_doc: hermes may not be installed; probe is best-effort
  $hermesBin = Get-HermesCliPath
  if ($null -ne $hermesBin) {
    Set-HermesGatewayRunValue -Name 'nucleus-hermes-gateway' -Command 'hermes --profile gateway gateway run --replace'
    Write-NucleusNotice "[$label] ensured HKCU Run value nucleus-hermes-gateway"
  } else {
    Write-NucleusWarning "[$label] hermes binary not found — cannot set gateway autostart"
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
