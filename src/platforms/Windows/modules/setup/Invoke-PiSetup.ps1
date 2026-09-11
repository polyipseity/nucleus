<#
.SYNOPSIS
  Idempotently converges the declarative pi coding agent extension set.

.DESCRIPTION
  Maintains a managed set of pi extensions installed with `pi install`.  On each
  apply it derives the installed set from pi's own records — the "packages" array
  in %USERPROFILE%\.pi\agent\settings.json unioned with the dependencies in
  %USERPROFILE%\.pi\agent\npm\package.json — removes anything installed but
  absent from the desired list (zap-style), and installs any desired extension
  that is missing or present at a version different from the repository lockfile
  pin.

  Versions come from the "pi" section of src\lockfiles\lockfile.json; install
  specs are built as "npm:<name>@<version>" because pi's source parser accepts
  only npm:, git: and local-path forms — a bare "name@version" is rejected.

  The desired list itself comes from the shared registry
  src\modules\packages\desired.json ("pi" -> current host), the same file POSIX
  install-pi-packages.sh consumes.

  Mirrors the install-pi-packages POSIX activation in src/modules/agents.nix.

  Every failure is a hard error: a registry/lockfile that cannot be read, an
  unresolvable pi executable, and any failed pi install/remove all report an
  error and return without pretending the machine converged.

  Requires pi on PATH — installed by Invoke-BunSetup as
  @earendil-works/pi-coding-agent.  Prepends %USERPROFILE%\.bun\bin to PATH
  internally so a pi installed during this apply run is usable here.

.EXAMPLE
  Invoke-PiSetup

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure.
#>
function Invoke-PiSetup {
  [CmdletBinding()]
  param()

  # Derive repo root from script location (src/platforms/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"
  $desiredPath = Join-Path $repoRoot "src\modules\packages\desired.json"

  # Get-NucleusHostKey resolves the canonical host key used to slice the shared
  # desired-package registry.
  . (Join-Path -Path $repoRoot -ChildPath "src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1")

  if (-not (Test-Path -LiteralPath $lockfilePath -PathType Leaf)) {
    $errMessage = "lockfile not found at '$lockfilePath'; cannot resolve pi extension versions"
    Write-NucleusError -CommandName 'pi-setup' $errMessage
    throw "Invoke-PiSetup: $errMessage"
  }
  if (-not (Test-Path -LiteralPath $desiredPath -PathType Leaf)) {
    $errMessage = "desired package registry not found at '$desiredPath'"
    Write-NucleusError -CommandName 'pi-setup' $errMessage
    throw "Invoke-PiSetup: $errMessage"
  }

  try {
    $lockfile = Get-Content -LiteralPath $lockfilePath -Raw | ConvertFrom-Json
    $registry = Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json
  } catch {
    $errMessage = "could not parse the lockfile or the desired-package registry: $($_.Exception.Message)"
    Write-NucleusError -CommandName 'pi-setup' $errMessage
    throw "Invoke-PiSetup: $errMessage"
  }

  $hostKey = Get-NucleusHostKey
  $hostDesired = $registry.pi.$hostKey
  if ($null -eq $hostDesired) {
    $errMessage = "desired package registry has no pi list for host '$hostKey'"
    Write-NucleusError -CommandName 'pi-setup' $errMessage
    throw "Invoke-PiSetup: $errMessage"
  }
  $desiredPackages = @($hostDesired | ForEach-Object { $_.name })

  $piVersions = @{}
  if ($lockfile -and $lockfile.pi) {
    foreach ($prop in $lockfile.pi.PSObject.Properties) {
      $piVersions[$prop.Name] = $prop.Value
    }
  }

  # Installed set: pi's settings.json registry (authoritative record of what pi
  # manages) unioned with the npm-install record.  A directory listing
  # is not a valid source — the npm tree also contains node_modules.
  $settingsPath = Join-Path $HOME ".pi\agent\settings.json"
  $installRecordPath = Join-Path $HOME ".pi\agent\npm\package.json"
  $installedPackages = @()
  $installedVersions = @{}

  if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
      $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    } catch {
      $errMessage = "could not parse the pi package registry '$settingsPath': $($_.Exception.Message)"
      Write-NucleusError -CommandName 'pi-setup' $errMessage
      throw "Invoke-PiSetup: $errMessage"
    }
    foreach ($spec in @($settings.packages)) {
      if ([string]::IsNullOrWhiteSpace($spec)) { continue }
      # Specs are "npm:<name>@<version>"; keep the leading @ of scoped names by
      # stripping only an @ that is not preceded by a path separator.
      $name = $spec -replace '^npm:', ''
      $name = $name -replace '@[^/@]*$', ''
      $installedPackages += $name
    }
  }

  if (Test-Path -LiteralPath $installRecordPath -PathType Leaf) {
    try {
      $installRecord = Get-Content -LiteralPath $installRecordPath -Raw | ConvertFrom-Json
    } catch {
      $errMessage = "could not parse the pi install record '$installRecordPath': $($_.Exception.Message)"
      Write-NucleusError -CommandName 'pi-setup' $errMessage
      throw "Invoke-PiSetup: $errMessage"
    }
    if ($null -ne $installRecord.dependencies) {
      foreach ($prop in $installRecord.dependencies.PSObject.Properties) {
        $installedPackages += $prop.Name
        $installedVersions[$prop.Name] = $prop.Value
      }
    }
  }

  # A package can appear in both records; collapse duplicates so it is neither
  # installed nor removed twice.
  $installedPackages = @($installedPackages | Sort-Object -Unique)

  # pi spawns the bare command "bun" for every npm: install (npmCommand in
  # src/users/default/agents/pi-settings.json), so bun's own directory must be
  # on the child PATH — the managed bin dir only holds bun-installed binaries.
  # check-suppress:suppression_doc: probe -- bun is provisioned by the WinGet DSC baseline; absence is reported below.
  $bunCommand = Get-Command bun -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $bunCommand) {
    $errMessage = "bun not found on PATH; ensure Oven-sh.Bun was installed before this step"
    Write-NucleusError -CommandName 'pi-setup' $errMessage
    throw "Invoke-PiSetup: $errMessage"
  }
  foreach ($bunDir in @((Split-Path -Parent $bunCommand.Source), (Get-NucleusManagedBinDir "bun"))) {
    if ($env:PATH -notlike "*$bunDir*") {
      $env:PATH = "$env:PATH;$bunDir"
    }
  }

  # check-suppress:suppression_doc: probe -- pi may not be installed; the if-guard reports the error below.
  $piCommand = Get-Command pi -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $piCommand) {
    $errMessage = "pi not found on PATH; ensure Invoke-BunSetup installed @earendil-works/pi-coding-agent before this step"
    Write-NucleusError -CommandName 'pi-setup' $errMessage
    throw "Invoke-PiSetup: $errMessage"
  }

  # Extensions installed but not desired: zap-style removal.
  $toRemove = @($installedPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired extensions that are missing, or present at a version different from
  # the lockfile pin (version-aware reconciliation).
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    if ($installedPackages -notcontains $pkg) { return $true }
    $pin = $piVersions[$pkg]
    if (-not $pin) { return $false }
    $installedVersions[$pkg] -ne $pin
  })

  foreach ($pkg in $toRemove) {
    Write-NucleusInfo -CommandName 'pi' "removing $pkg"
    & $piCommand.Source remove "npm:$pkg"
    if ($LASTEXITCODE -ne 0) {
      $errMessage = "'pi remove npm:$pkg' failed (exit $LASTEXITCODE)"
      Write-NucleusError -CommandName 'pi' $errMessage
      throw "Invoke-PiSetup: $errMessage"
    }
    Write-NucleusInfo -CommandName 'pi' "$pkg removed"
  }

  foreach ($pkg in $toInstall) {
    $pin = $piVersions[$pkg]
    $installSpec = if ($pin) { "npm:$pkg@$pin" } else { "npm:$pkg" }
    Write-NucleusInfo -CommandName 'pi' "installing $installSpec"
    & $piCommand.Source install $installSpec --no-approve
    if ($LASTEXITCODE -ne 0) {
      $errMessage = "'pi install $installSpec' failed (exit $LASTEXITCODE)"
      Write-NucleusError -CommandName 'pi' $errMessage
      throw "Invoke-PiSetup: $errMessage"
    }
    Write-NucleusInfo -CommandName 'pi' "$pkg installed successfully"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-NucleusInfo -CommandName 'pi' "all managed extensions already converged — skipping"
  }
}
